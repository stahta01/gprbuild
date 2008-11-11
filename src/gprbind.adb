------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                              G P R B I N D                               --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--            Copyright (C) 2006-2008, Free Software Foundation, Inc.       --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 2,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNAT;  see file COPYING.  If not, write --
-- to  the  Free Software Foundation,  51  Franklin  Street,  Fifth  Floor, --
-- Boston, MA 02110-1301, USA.                                              --
--                                                                          --
-- GNAT was originally developed  by the GNAT team at  New York University. --
-- Extensive contributions were provided by Ada Core Technologies Inc.      --
--                                                                          --
------------------------------------------------------------------------------

--  gprbind is the executable called by gprmake to bind Ada sources. It is
--  the driver for gnatbind. It gets its input from gprmake through the
--  binding exchange file and gives back its results through the same file.

with Ada.Text_IO; use Ada.Text_IO;

with Ada.Command_Line; use Ada.Command_Line;
with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.OS_Lib;      use GNAT.OS_Lib;

with ALI;      use ALI;
with Gprexch;  use Gprexch;
with Gpr_Util; use Gpr_Util;
with Hostparm;
with Makeutl;  use Makeutl;
with Namet;    use Namet;
with Osint;
with Switch;
with Tempdir;
with Table;
with Types;

procedure Gprbind is

   Preserve : Attribute := Time_Stamps;
   --  Used in calls to Copy_File. Changed to None for OpenVMS, because
   --  Copy_Attributes always fails on VMS.

   Executable_Suffix : constant String_Access := Get_Executable_Suffix;
   --  The suffix of executables on this platforms

   GNATBIND : String_Access := new String'("gnatbind");
   --  The file name of the gnatbind executable. May be modified by an option
   --  in the Minimum_Binder_Options.

   Gnatbind_Prefix_Equal : constant String := "gnatbind_prefix=";
   --  Start of the option to specify a prefix for the gnatbind executable.

   Ada_Binder_Equal : constant String := "ada_binder=";
   --  Start of the option to specify the full name of the Ada binder
   --  executable. Introduced for GNAAMP, where it is gnaambind.

   Quiet_Output : Boolean := False;
   Verbose_Mode : Boolean := False;

   No_Main_Option : constant String := "-n";
   Dash_o         : constant String := "-o";
   Dash_shared    : constant String := "-shared";
   Dash_x         : constant String := "-x";
   Dash_OO        : constant String := "-O";

   --  Minimum switches to be used to compile the binder generated file

   Dash_c      : constant String := "-c";
   Dash_gnatA  : constant String := "-gnatA";
   Dash_gnatWb : constant String := "-gnatWb";
   Dash_gnatiw : constant String := "-gnatiw";

   GCC_Version : Character := '0';
   Gcc_Version_String : constant String := "gcc version ";

   Shared_Libgcc : constant String := "-shared-libgcc";
   Static_Libgcc : constant String := "-static-libgcc";

   IO_File : File_Type;
   --  The file to get the inputs and to put the results of the binding

   Line : String (1 .. 1_000);
   Last : Natural;

   Exchange_File_Name : String_Access;
   Ada_Compiler_Path  : String_Access;
   Gnatbind_Path      : String_Access;

   Compiler_Options     : String_List_Access := new String_List (1 .. 100);
   Last_Compiler_Option : Natural := 0;

   Gnatbind_Options     : String_List_Access := new String_List (1 .. 100);
   Last_Gnatbind_Option : Natural := 0;

   Main_ALI : String_Access := null;

   Main_Base_Name        : String_Access := null;
   Binder_Generated_File : String_Access := null;
   BG_File               : File_Type;

   Success     : Boolean := False;
   Return_Code : Integer;

   Adalib_Dir  : String_Access;
   Prefix_Path : String_Access;
   Lib_Path    : String_Access;

   Static_Libs : Boolean := True;

   Current_Section : Binding_Section := No_Binding_Section;

   All_Binding_Options : Boolean;
   Get_Option          : Boolean;

   GNAT_Version : String_Access := new String'("000");
   --  The version of GNAT, coming from the Toolchain_Version for Ada

   Delete_Temp_Files : Boolean := True;

   FD_Objects   : File_Descriptor;
   Objects_Path : Path_Name_Type;
   Objects_File : File_Type;

   package Binding_Options_Table is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100,
      Table_Name           => "Gprbind.Binding_Options_Table");

   package ALI_Files_Table is new Table.Table
     (Table_Component_Type => String_Access,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100,
      Table_Name           => "Gprbind.ALI_File_Table");

   type Path_And_Stamp is record
      Path : String_Access;
      Stamp : String_Access;
   end record;

   package Project_Paths is new Table.Table
     (Table_Component_Type => Path_And_Stamp,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100,
      Table_Name           => "Gprbind.Project_Paths");

   type Bound_File;
   type Bound_File_Access is access Bound_File;
   type Bound_File is record
      Name : String_Access;
      Next : Bound_File_Access;
   end record;

   Bound_Files : Bound_File_Access;

begin
   if Argument_Count /= 1 then
      Osint.Fail ("incorrect invocation");
   end if;

   Namet.Initialize;

   --  Copy_Attributes always fails on VMS

   if Hostparm.OpenVMS then
      Preserve := None;
   end if;

   Exchange_File_Name := new String'(Argument (1));

   --  DEBUG: save a copy of the exchange file

   declare
      Gprbind_Debug : constant String := Getenv ("GPRBIND_DEBUG").all;

   begin
      if Gprbind_Debug = "TRUE" then
         Copy_File
           (Exchange_File_Name.all,
            Exchange_File_Name.all & "__saved",
            Success,
            Mode => Overwrite,
            Preserve => Preserve);
      end if;
   end;

   --  Open the binding exchange file

   begin
      Open (IO_File, In_File, Exchange_File_Name.all);
   exception
      when others =>
         Osint.Fail ("could not read " & Exchange_File_Name.all);
   end;

   --  Get the information from the binding exchange file

   while not End_Of_File (IO_File) loop
      Get_Line (IO_File, Line, Last);

      if Last > 0 then
         if Line (1) = '[' then
            Current_Section := Get_Binding_Section (Line (1 .. Last));

            case Current_Section is
               when No_Binding_Section =>
                  Osint.Fail ("unknown section: " & Line (1 .. Last));

               when Quiet =>
                  Quiet_Output := True;
                  Verbose_Mode := False;

               when Verbose =>
                  Quiet_Output := False;
                  Verbose_Mode := True;

               when Shared_Libs =>
                  Static_Libs := False;

               when others =>
                  null;
            end case;

         else
            case Current_Section is
               when No_Binding_Section =>
                  Osint.Fail ("no section specified: " & Line (1 .. Last));

               when Quiet =>
                  Osint.Fail ("quiet section should be empty");

               when Verbose =>
                  Osint.Fail ("verbose section should be empty");

               when Shared_Libs =>
                  Osint.Fail ("shared libs section should be empty");

               when Gprexch.Main_Base_Name =>
                  if Main_Base_Name /= null then
                     Osint.Fail
                       ("main base name specified multiple times");
                  end if;

                  Main_Base_Name := new String'(Line (1 .. Last));

               when Compiler_Path =>
                  if Ada_Compiler_Path /= null then
                     Osint.Fail
                       ("compiler path specified multiple times");
                  end if;

                  Ada_Compiler_Path := new String'(Line (1 .. Last));

               when Main_Dependency_File =>
                  if Main_ALI /= null then
                     Osint.Fail ("main ALI file specified multiple times");
                  end if;

                  Main_ALI := new String'(Line (1 .. Last));

               when Dependency_Files =>
                  ALI_Files_Table.Append (new String'(Line (1 .. Last)));

               when Binding_Options =>
                  --  Check if a gnatbind prefix is specified

                  if Last > Gnatbind_Prefix_Equal'Length
                    and then Line (1 .. Gnatbind_Prefix_Equal'Length) =
                             Gnatbind_Prefix_Equal
                  then
                     --  There is always a '-' between <prefix> and "gnatbind".
                     --  Add one if not already in <prefix>.

                     if Line (Last) /= '-' then
                        Last := Last + 1;
                        Line (Last) := '-';
                     end if;

                     GNATBIND := new String'
                       (Line (Gnatbind_Prefix_Equal'Length + 1 .. Last) &
                        "gnatbind");

                  elsif Last > Ada_Binder_Equal'Length
                    and then Line (1 .. Ada_Binder_Equal'Length) =
                             Ada_Binder_Equal
                  then
                     GNATBIND := new String'
                       (Line (Ada_Binder_Equal'Length + 1 .. Last));

                  else
                     Binding_Options_Table.Append
                                             (new String'(Line (1 .. Last)));
                  end if;

               when Project_Files =>
                  if End_Of_File (IO_File) then
                     Osint.Fail ("no time stamp for " & Line (1 .. Last));

                  else
                     declare
                        PS : Path_And_Stamp;

                     begin
                        PS.Path := new String'(Line (1 .. Last));
                        Get_Line (IO_File, Line, Last);
                        PS.Stamp := new String'(Line (1 .. Last));
                        Project_Paths.Append (PS);
                     end;
                  end if;

               when Gprexch.Toolchain_Version =>
                  if End_Of_File (IO_File) then
                     Osint.Fail
                       ("no toolchain version for language " &
                        Line (1 .. Last));

                  elsif Line (1 .. Last) = "ada" then
                     Get_Line (IO_File, Line, Last);

                     if Last > 5 and then Line (1 .. 5) = "GNAT " then
                        GNAT_Version := new String'(Line (6 .. Last));
                     end if;

                  else
                     Skip_Line (IO_File);
                  end if;

               when Gprexch.Delete_Temp_Files =>
                  begin
                     Delete_Temp_Files := Boolean'Value (Line (1 .. Last));

                  exception
                     when Constraint_Error =>
                        null;
                  end;

               when Generated_Object_File |
                    Generated_Source_Files |
                    Bound_Object_Files |
                    Resulting_Options |
                    Run_Path_Option =>
                  null;
            end case;
         end if;
      end if;
   end loop;

   if Main_Base_Name = null then
      Osint.Fail ("no main base name specified");

   else
      Binder_Generated_File :=
        new String'("b__" & Main_Base_Name.all & ".adb");
   end if;

   Close (IO_File);

   Add (Dash_x, Gnatbind_Options, Last_Gnatbind_Option);

   if not Static_Libs then
      Add (Dash_shared, Gnatbind_Options, Last_Gnatbind_Option);
   end if;

   --  Specify the name of the generated file to gnatbind

   Add (Dash_o, Gnatbind_Options, Last_Gnatbind_Option);
   Add
     (Binder_Generated_File.all,
      Gnatbind_Options,
      Last_Gnatbind_Option);

   if not Is_Regular_File (Ada_Compiler_Path.all) then
      Osint.Fail ("could not find the Ada compiler");
   end if;

   if Main_ALI /= null then
      Add (Main_ALI.all, Gnatbind_Options, Last_Gnatbind_Option);
   end if;

   if GNAT_Version.all >= "5.01" then
      Add ("-F", Gnatbind_Options, Last_Gnatbind_Option);
   end if;

   for J in 1 .. ALI_Files_Table.Last loop
      Add (ALI_Files_Table.Table (J), Gnatbind_Options, Last_Gnatbind_Option);
   end loop;

   for J in 1 .. Binding_Options_Table.Last loop
      Add
        (Binding_Options_Table.Table (J),
         Gnatbind_Options,
         Last_Gnatbind_Option);
   end loop;

   if Ada_Compiler_Path /= null and then
      not Is_Absolute_Path (GNATBIND.all)
   then
      GNATBIND :=
        new String'
              (Dir_Name (Ada_Compiler_Path.all) &
               Directory_Separator &
               GNATBIND.all);
   end if;

   Gnatbind_Path := Locate_Exec_On_Path (GNATBIND.all);

   if Gnatbind_Path = null then
      Osint.Fail ("could not locate " & GNATBIND.all);

   else
      --  Normalize the path, so that gnaampbind does not complain about not
      --  being in a "bib" directory. But don't resolve symbolic links,
      --  because in GNAT 5.01a1 and previous releases, gnatbind was a symbolic
      --  link for .gnat_wrapper.

      Gnatbind_Path :=
        new String'
          (Normalize_Pathname (Gnatbind_Path.all, Resolve_Links => False));
   end if;

   if Main_ALI = null then
      Add (No_Main_Option, Gnatbind_Options, Last_Gnatbind_Option);
   end if;

   Add (Dash_OO, Gnatbind_Options, Last_Gnatbind_Option);

   if not Quiet_Output then
      if Verbose_Mode then
         Put (Gnatbind_Path.all);
      else
         Put (Base_Name (GNATBIND.all));
      end if;

      if Verbose_Mode then
         for Option in 1 .. Last_Gnatbind_Option loop
            Put (' ');
            Put (Gnatbind_Options (Option).all);
         end loop;

      else
         Put (' ');

         if Main_ALI /= null then
            Put (Base_Name (Main_ALI.all));

            if ALI_Files_Table.Last > 0 then
               Put (" ...");
            end if;

         elsif ALI_Files_Table.Last > 0 then
            Put (Base_Name (ALI_Files_Table.Table (1).all));

            if ALI_Files_Table.Last > 1 then
               Put (" ...");
            end if;

            Put (' ');
            Put (No_Main_Option);
         end if;
      end if;

      New_Line;
   end if;

   declare
      Size : Natural := 0;
      Maximum_Size : Integer;
      pragma Import (C, Maximum_Size, "__gnat_link_max");
      --  Maximum number of bytes to put in an invocation of the
      --  gnatbind.

   begin
      for J in 1 .. Last_Gnatbind_Option loop
         Size := Size + Gnatbind_Options (J)'Length + 1;
      end loop;

      --  Create temporary file to get the list of objects

      Tempdir.Create_Temp_File (FD_Objects, Objects_Path);

      --  Invoke gnatbind with the arguments if the size is not too large or
      --  if the version of GNAT is not recent enough.

      if GNAT_Version.all < "6" or else Size <= Maximum_Size then
         Spawn
           (Gnatbind_Path.all,
            Gnatbind_Options (1 .. Last_Gnatbind_Option),
            FD_Objects,
            Return_Code,
            Err_To_Out => False);

      else
         --  Otherwise create a temporary response file

         declare
            FD            : File_Descriptor;
            Path          : Path_Name_Type;
            Args          : Argument_List (1 .. 1);
            EOL           : constant String (1 .. 1) := (1 => ASCII.LF);
            Status        : Integer;
            Succ          : Boolean;
            Quotes_Needed : Boolean;
            Last_Char     : Natural;
            Ch            : Character;

         begin
            Tempdir.Create_Temp_File (FD, Path);
            Args (1) := new String'("@" & Get_Name_String (Path));

            for J in 1 .. Last_Gnatbind_Option loop

               --  Check if the argument should be quoted

               Quotes_Needed := False;
               Last_Char     := Gnatbind_Options (J)'Length;

               for K in Gnatbind_Options (J)'Range loop
                  Ch := Gnatbind_Options (J) (K);

                  if Ch = ' ' or else Ch = ASCII.HT or else Ch = '"' then
                     Quotes_Needed := True;
                     exit;
                  end if;
               end loop;

               if Quotes_Needed then

                  --  Quote the argument, doubling '"'

                  declare
                     Arg : String (1 .. Gnatbind_Options (J)'Length * 2 + 2);

                  begin
                     Arg (1) := '"';
                     Last_Char := 1;

                     for K in Gnatbind_Options (J)'Range loop
                        Ch := Gnatbind_Options (J) (K);
                        Last_Char := Last_Char + 1;
                        Arg (Last_Char) := Ch;

                        if Ch = '"' then
                           Last_Char := Last_Char + 1;
                           Arg (Last_Char) := '"';
                        end if;
                     end loop;

                     Last_Char := Last_Char + 1;
                     Arg (Last_Char) := '"';

                     Status := Write (FD, Arg'Address, Last_Char);
                  end;

               else
                  Status := Write
                    (FD,
                     Gnatbind_Options (J) (Gnatbind_Options (J)'First)'Address,
                     Last_Char);
               end if;

               if Status /= Last_Char then
                  Osint.Fail ("disk full");
               end if;

               Status := Write (FD, EOL (1)'Address, 1);

               if Status /= 1 then
                  Osint.Fail ("disk full");
               end if;
            end loop;

            Close (FD);

            --  And invoke gnatbind with this this response file

            Spawn
              (Gnatbind_Path.all,
               Args,
               FD_Objects,
               Return_Code,
               Err_To_Out => False);

            if Delete_Temp_Files then
               Delete_File (Get_Name_String (Path), Succ);

               if not Succ then
                  null;
               end if;
            end if;

         end;
      end if;
   end;

   Close (FD_Objects);

   if Return_Code /= 0 then
      if Delete_Temp_Files then
         Delete_File (Get_Name_String (Objects_Path), Success);
      end if;

      Osint.Fail ("invocation of gnatbind failed");
   end if;

   Add (Dash_c, Compiler_Options, Last_Compiler_Option);
   Add (Dash_gnatA, Compiler_Options, Last_Compiler_Option);
   Add (Dash_gnatWb, Compiler_Options, Last_Compiler_Option);
   Add (Dash_gnatiw, Compiler_Options, Last_Compiler_Option);

   --  Read the ALI file of the first ALI file. Fetch the back end switches
   --  from this ALI file and use these switches to compile the binder
   --  generated file.

   if Main_ALI /= null or else ALI_Files_Table.Last >= 1 then
      Initialize_ALI;
      Name_Len := 0;

      if Main_ALI /= null then
         Add_Str_To_Name_Buffer (Main_ALI.all);

      else
         Add_Str_To_Name_Buffer (ALI_Files_Table.Table (1).all);
      end if;

      declare
         use Types;
         F : constant File_Name_Type := Name_Find;
         T : Text_Buffer_Ptr;
         A : ALI_Id;

      begin
         --  Load the ALI file

         T := Osint.Read_Library_Info (F, True);

         --  Read it. Note that we ignore errors, since we only want very
         --  limited information from the ali file, and likely a slightly
         --  wrong version will be just fine, though in normal operation
         --  we don't expect this to happen!

         A := Scan_ALI
               (F,
                T,
                Ignore_ED     => False,
                Err           => False,
                Ignore_Errors => True,
                Read_Lines    => "A");

         if A /= No_ALI_Id then
            for
              Index in Units.Table (ALIs.Table (A).First_Unit).First_Arg ..
                       Units.Table (ALIs.Table (A).First_Unit).Last_Arg
            loop
               --  Do not compile with the front end switches. However, --RTS
               --  is to be dealt with specially because the binder-generated
               --  file need to compiled with the same switch.

               declare
                  Arg : String_Ptr renames Args.Table (Index);
               begin
                  if (not Switch.Is_Front_End_Switch (Arg.all))
                     or else
                     (Arg'Length > 5
                      and then
                      Arg (Arg'First + 2 .. Arg'First + 5) = "RTS=")
                  then
                     Add
                       (String_Access (Arg),
                        Compiler_Options,
                        Last_Compiler_Option);
                  end if;
               end;
            end loop;
         end if;
      end;
   end if;

   Add (Binder_Generated_File, Compiler_Options, Last_Compiler_Option);

   declare
      Object : constant String := "b__" & Main_Base_Name.all & ".o";
   begin
      Add
        (Dash_o,
         Compiler_Options,
         Last_Compiler_Option);
      Add
        (Object,
         Compiler_Options,
         Last_Compiler_Option);

      if not Quiet_Output then
         Name_Len := 0;

         if Verbose_Mode then
            Add_Str_To_Name_Buffer (Ada_Compiler_Path.all);
         else
            Add_Str_To_Name_Buffer (Base_Name (Ada_Compiler_Path.all));
         end if;

         --  Remove the executable suffix, if present

         if Executable_Suffix'Length > 0
           and then
             Name_Len > Executable_Suffix'Length
           and then
               Name_Buffer
                 (Name_Len - Executable_Suffix'Length + 1 .. Name_Len) =
               Executable_Suffix.all
         then
            Name_Len := Name_Len - Executable_Suffix'Length;
         end if;

         Put (Name_Buffer (1 .. Name_Len));

         if Verbose_Mode then
            for Option in 1 .. Last_Compiler_Option loop
               Put (' ');
               Put (Compiler_Options (Option).all);
            end loop;

         else
            Put (' ');
            Put (Compiler_Options (1).all);

            if Compiler_Options (1) /= Binder_Generated_File then
               Put (' ');
               Put (Binder_Generated_File.all);
            end if;
         end if;

         New_Line;
      end if;

      Spawn
        (Ada_Compiler_Path.all,
         Compiler_Options (1 .. Last_Compiler_Option),
         Success);

      if not Success then
         Osint.Fail ("compilation of binder generated file failed");
      end if;

      --  Find the GCC version

      Spawn
        (Program_Name => Ada_Compiler_Path.all,
         Args         => (1 => new String'("-v")),
         Output_File  => Exchange_File_Name.all,
         Success      => Success,
         Return_Code  => Return_Code,
         Err_To_Out   => True);

      if Success then
         Open (IO_File, In_File, Exchange_File_Name.all);
         while not End_Of_File (IO_File) loop
            Get_Line (IO_File, Line, Last);

            if Last > Gcc_Version_String'Length and then
              Line (1 .. Gcc_Version_String'Length) = Gcc_Version_String
            then
               GCC_Version := Line (Gcc_Version_String'Length + 1);
               exit;
            end if;
         end loop;

         Close (IO_File);
      end if;

      Create (IO_File, Out_File, Exchange_File_Name.all);

      --  First, the generated object file

      Put_Line (IO_File, Binding_Label (Generated_Object_File));
      Put_Line (IO_File, Object);

      --  Repeat the project paths with their time stamps

      Put_Line (IO_File, Binding_Label (Project_Files));

      for J in 1 .. Project_Paths.Last loop
         Put_Line (IO_File, Project_Paths.Table (J).Path.all);
         Put_Line (IO_File, Project_Paths.Table (J).Stamp.all);
      end loop;

      --  Get the bound object files from the Object file

      Open (Objects_File, In_File, Get_Name_String (Objects_Path));

      Put_Line (IO_File, Binding_Label (Bound_Object_Files));

      while not End_Of_File (Objects_File) loop
         Get_Line (Objects_File, Line, Last);
         Put_Line (IO_File, Line (1 .. Last));

         Bound_Files := new Bound_File'
           (Name => new String'(Line (1 .. Last)), Next => Bound_Files);
      end loop;

      Close (Objects_File);

      if Delete_Temp_Files then
         Delete_File (Get_Name_String (Objects_Path), Success);
      end if;

      --  For the benefit of gprclean, the generated files other than the
      --  generated object file.

      Put_Line (IO_File, Binding_Label (Generated_Source_Files));
      Put_Line (IO_File, "b__" & Main_Base_Name.all & ".ads");
      Put_Line (IO_File, Binder_Generated_File.all);
      Put_Line (IO_File, "b__" & Main_Base_Name.all & ".ali");

      --  Get the options from the binder generated file

      Open (BG_File, In_File, Binder_Generated_File.all);

      while not End_Of_File (BG_File) loop
         Get_Line (BG_File, Line, Last);
         exit when Line (1 .. Last) = Begin_Info;
      end loop;

      if not End_Of_File (BG_File) then
         Put_Line (IO_File, Binding_Label (Resulting_Options));

         All_Binding_Options := False;
         loop
            Get_Line (BG_File, Line, Last);
            exit when Line (1 .. Last) = End_Info;
            Line (1 .. Last - 8) := Line (9 .. Last);
            Last := Last - 8;

            if Line (1) = '-' then
               --  After the first switch, we take all options, because some
               --  of the options specified in pragma Linker_Options may not
               --  start with '-'.
               All_Binding_Options := True;
            end if;

            Get_Option :=
              All_Binding_Options
              or else
              (Base_Name (Line (1 .. Last)) = "g-trasym.o")
              or else
              (Base_Name (Line (1 .. Last)) = "g-trasym.obj");
            --  g-trasym is a special case as it is not included in libgnat

            --  Avoid duplication of object file

            if Get_Option then
               declare
                  BF : Bound_File_Access := Bound_Files;

               begin
                  while BF /= null loop
                     if BF.Name.all = Line (1 .. Last) then
                        Get_Option := False;
                        exit;

                     else
                        BF := BF.Next;
                     end if;
                  end loop;
               end;
            end if;

            if Get_Option then
               if Last >= 3 and then Line (1 .. 2) = "-L" then
                  --  Set Adalib_Dir only if libgnat is found inside.
                  if Is_Regular_File (Line (3 .. Last) &
                                      Directory_Separator & "libgnat.a")
                  then
                     Adalib_Dir := new String'(Line (3 .. Last));

                     if Verbose_Mode then
                        Put_Line ("Adalib_Dir = """ & Adalib_Dir.all & '"');
                     end if;

                     --  Build the Prefix_Path, where to look for some
                     --  archives: libaddr2line.a, libbfd.a, libgnatmon.a,
                     --  libgnalasup.a and libiberty.a. It contains three
                     --  directories: $(adalib)/.., $(adalib)/../.. and the
                     --  subdirectory "lib" ancestor of $(adalib).

                     declare
                        Dir_Last       : Positive;
                        Prev_Dir_Last  : Positive;
                        First          : Positive;
                        Prev_Dir_First : Positive;
                        Nmb            : Natural;
                     begin
                        Name_Len := 0;
                        Add_Str_To_Name_Buffer (Line (3 .. Last));

                        while Name_Buffer (Name_Len) = Directory_Separator
                          or else Name_Buffer (Name_Len) = '/'
                        loop
                           Name_Len := Name_Len - 1;
                        end loop;

                        while Name_Buffer (Name_Len) /= Directory_Separator
                          and then Name_Buffer (Name_Len) /= '/'
                        loop
                           Name_Len := Name_Len - 1;
                        end loop;

                        while Name_Buffer (Name_Len) = Directory_Separator
                          or else Name_Buffer (Name_Len) = '/'
                        loop
                           Name_Len := Name_Len - 1;
                        end loop;

                        Dir_Last := Name_Len;
                        Nmb := 0;

                        Dir_Loop : loop
                           Prev_Dir_Last := Dir_Last;
                           First := Dir_Last - 1;
                           while First > 3
                             and then
                              Name_Buffer (First) /= Directory_Separator
                             and then
                              Name_Buffer (First) /= '/'
                           loop
                              First := First - 1;
                           end loop;

                           Prev_Dir_First := First + 1;

                           exit Dir_Loop when First <= 3;

                           Dir_Last := First - 1;
                           while Name_Buffer (Dir_Last) = Directory_Separator
                             or else Name_Buffer (Dir_Last) = '/'
                           loop
                              Dir_Last := Dir_Last - 1;
                           end loop;

                           Nmb := Nmb + 1;

                           if Nmb <= 1 then
                              Add_Char_To_Name_Buffer (Path_Separator);
                              Add_Str_To_Name_Buffer
                                (Name_Buffer (1 .. Dir_Last));

                           elsif Name_Buffer (Prev_Dir_First .. Prev_Dir_Last)
                             = "lib"
                           then
                              Add_Char_To_Name_Buffer (Path_Separator);
                              Add_Str_To_Name_Buffer
                                (Name_Buffer (1 .. Prev_Dir_Last));
                              exit Dir_Loop;
                           end if;
                        end loop Dir_Loop;

                        Prefix_Path :=
                          new String'(Name_Buffer (1 .. Name_Len));

                        if Verbose_Mode then
                           Put_Line
                             ("Prefix_Path = """ & Prefix_Path.all & '"');
                        end if;
                     end;
                  end if;
                  Put_Line (IO_File, Line (1 .. Last));

               elsif Line (1 .. Last) = "-static" then
                  Static_Libs := True;
                  Put_Line (IO_File, Line (1 .. Last));

                  if GCC_Version >= '3' then
                     Put_Line (IO_File, Static_Libgcc);
                  end if;

               elsif Line (1 .. Last) = "-shared" then
                  Static_Libs := False;
                  Put_Line (IO_File, Line (1 .. Last));

                  if GCC_Version >= '3' then
                     Put_Line (IO_File, Shared_Libgcc);
                  end if;

                  --  For a number of archives, we need to indicate the full
                  --  path of the archive, if we find it, to be sure that the
                  --  correct archive is used by the linker.

               elsif Line (1 .. Last) = "-lgnat" then
                  if Adalib_Dir = null then
                     if Verbose_Mode then
                        Put_Line ("No Adalib_Dir");
                     end if;

                     Put_Line (IO_File, "-lgnat");

                  elsif Static_Libs then
                     Put_Line (IO_File, Adalib_Dir.all & "libgnat.a");

                  else
                     Put_Line (IO_File, "-lgnat");
                  end if;

               elsif Line (1 .. Last) = "-lgnarl" and then
                     Static_Libs and then
                     Adalib_Dir /= null
               then
                  Put_Line (IO_File, Adalib_Dir.all & "libgnarl.a");

               elsif Line (1 .. Last) = "-laddr2line"
                 and then Prefix_Path /= null
               then
                  Lib_Path := Locate_Regular_File
                    ("libaddr2line.a", Prefix_Path.all);

                  if Lib_Path /= null then
                     Put_Line (IO_File, Lib_Path.all);
                     Free (Lib_Path);

                  else
                     Put_Line (IO_File, Line (1 .. Last));
                  end if;

               elsif Line (1 .. Last) = "-lbfd"
                 and then Prefix_Path /= null
               then
                  Lib_Path := Locate_Regular_File
                    ("libbfd.a", Prefix_Path.all);

                  if Lib_Path /= null then
                     Put_Line (IO_File, Lib_Path.all);
                     Free (Lib_Path);

                  else
                     Put_Line (IO_File, Line (1 .. Last));
                  end if;

               elsif Line (1 .. Last) = "-lgnalasup"
                 and then Prefix_Path /= null
               then
                  Lib_Path := Locate_Regular_File
                    ("libgnalasup.a", Prefix_Path.all);

                  if Lib_Path /= null then
                     Put_Line (IO_File, Lib_Path.all);
                     Free (Lib_Path);

                  else
                     Put_Line (IO_File, Line (1 .. Last));
                  end if;

               elsif Line (1 .. Last) = "-lgnatmon"
                 and then Prefix_Path /= null
               then
                  Lib_Path := Locate_Regular_File
                    ("libgnatmon.a", Prefix_Path.all);

                  if Lib_Path /= null then
                     Put_Line (IO_File, Lib_Path.all);
                     Free (Lib_Path);

                  else
                     Put_Line (IO_File, Line (1 .. Last));
                  end if;

               elsif Line (1 .. Last) = "-liberty"
                 and then Prefix_Path /= null
               then
                  Lib_Path := Locate_Regular_File
                    ("libiberty.a", Prefix_Path.all);

                  if Lib_Path /= null then
                     Put_Line (IO_File, Lib_Path.all);
                     Free (Lib_Path);

                  else
                     Put_Line (IO_File, Line (1 .. Last));
                  end if;

               else
                  Put_Line (IO_File, Line (1 .. Last));
               end if;
            end if;
         end loop;
      end if;

      Close (BG_File);

      if not Static_Libs then
         Put_Line (IO_File, Binding_Label (Run_Path_Option));
         Put_Line (IO_File, Adalib_Dir.all);
         Name_Len := Adalib_Dir'Length;
         Name_Buffer (1 .. Name_Len) := Adalib_Dir.all;

         for J in reverse 2 .. Name_Len - 4 loop
            if Name_Buffer (J) = Directory_Separator and then
              Name_Buffer (J + 4) = Directory_Separator and then
              Name_Buffer (J + 1 .. J + 3) = "lib"
            then
               Name_Len := J + 3;
               Put_Line (IO_File, Name_Buffer (1 .. Name_Len));
               exit;
            end if;
         end loop;
      end if;

      Close (IO_File);
   end;
end Gprbind;
