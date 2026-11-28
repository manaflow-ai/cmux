# This file is part of Valgrind, a dynamic binary instrumentation
# framework.

# Copyright (C) 2022-2022 Philippe Waroquiers

# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of the
# License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program; if not, see <http://www.gnu.org/licenses/>.

# The GNU General Public License is contained in the file COPYING.
   
"""
This file defines a series of gdb commands and subcommands to help interfacing
gdb with the Valgrind gdbserver.

!!! This only works with GDB version >= 9.1, as some command names contains
a dot character only allowed from this version onwards.

Type "help valgrind" to get help about the top of the command hierarchy.
"""

from typing import Callable
from enum import Enum
import re

class _Debug_Valgrind_Execute_Monitor(gdb.Parameter):
    """Set valgrind monitor command execution debugging.
Usage: set debug valgrind-execute-monitor [on|off]"""
    def __init__(self):
        super().__init__("debug valgrind-execute-monitor",
                         gdb.COMMAND_MAINTENANCE,
                         gdb.PARAM_BOOLEAN)

Debug_Valgrind_Execute_Monitor = _Debug_Valgrind_Execute_Monitor()

def gdb_execute_monitor(monitor_command : str, from_tty : bool) -> None:
    """Execute the given monitor command."""
    cmd = "monitor " + monitor_command
    if Debug_Valgrind_Execute_Monitor.value:
        print('[valgrind-execute-monitor] sending "' + cmd + '" to valgrind')
    try:
        gdb.execute (cmd, from_tty)
    except Exception as inst:
        if monitor_command == "v.kill" and str(inst).find('Remote connection closed') >= 0:
            print('Remote connection closed')
        else:
            print('Error sending "' + monitor_command + '" to valgrind: '+ str(inst))

class Valgrind_Command(gdb.Command):
    """Parent class for all Valgrind commands."""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        """Generic Valgrind Command invoke method to override if needed."""
        # print("generic invoke", self.mname)
        if arg_str:
            gdb_execute_monitor (self.mname + " " + arg_str, from_tty)
        else:
            gdb_execute_monitor (self.mname, from_tty)

def Vinit(toolname : str,
          mname : str,
          command_class : Enum,
          completer_class : Enum,
          prefix : bool) -> Callable[[Valgrind_Command],
                                                Valgrind_Command]:
    """Class decorator to initialise and register a Valgrind_Command class.
MNAME is the Valgrind monitor name string for this command.
The gdb command is the concatenation of TOOLNAME and MNAME.
TOOLNAME is valgrind for the general valgrind commands."""
    def instantiate(GDB_Command : Valgrind_Command) -> Valgrind_Command:
        def adhoc_init (self):
            # print("initializing", GDB_Command)
            if completer_class:
                super(GDB_Command, self).__init__(name = toolname + " " + mname,
                                                  command_class = command_class,
                                                  completer_class = completer_class,
                                                  prefix = prefix)
            else:
                super(GDB_Command, self).__init__(name = toolname + " " + mname,
                                                  command_class = command_class,
                                                  prefix = prefix)
            self.toolname=toolname
            self.mname=mname
        GDB_Command.__init__ = adhoc_init
        GDB_Command() # register the command
        return GDB_Command
    return instantiate

def build_name(command : Valgrind_Command) -> str:
    """Returns the GDB full name for the given COMMAND."""
    if command.mname:
        return command.toolname + ' ' + command.mname
    else:
        return command.toolname

def build_help(command : Valgrind_Command) -> str:
    """Returns a string to ask help for the given COMMAND."""
    return "help " + build_name(command)

def build_type_help(command : Valgrind_Command) -> str:
    """Returns a string giving what to type to get helps about the given command"""
    return 'Type "' + build_help(command) + '"'

class Valgrind_Prefix_Command(Valgrind_Command):
    """Parent class for all Valgrind prefix commands."""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        """Generic Valgrind prefix Command invoke method to override if needed."""
        # print("generic prefix invoke", self.mname)
        if arg_str:
            # If it is not a recognised sub-command, raise an error.
            raise gdb.GdbError(('Undefined ' + build_name (self)
                                + ' command: "' + arg_str + '".\n'
                                + build_type_help(self)))
        else:
            gdb.execute (build_help(self), from_tty)

class Valgrind_Prefix_Exec_Command(Valgrind_Prefix_Command):
    """Parent class for all Valgrind prefix commands that can be executed without subcommands."""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        """Invoke for a prefix command that can be executed."""
        if arg_str:
            super().invoke(arg_str, from_tty)
        else:
            gdb_execute_monitor (self.mname, from_tty)

def eval_execute(command : Valgrind_Command,
                 arg_str : str,
                 arg_opt : bool, arg_descr : str, format_fn,
                 from_tty : bool) -> None:
    """Evaluates ARG_STR, format the result with FORMAT_FN and
executes the monitor command COMMAND.mname + FORMAT_FN(evaluated ARG_STR).
ARG_OPT True indicates the argument is optional.
ARG_DESCR is used in error messages."""
    if arg_str:
        eval_arg_str = gdb.parse_and_eval (arg_str)
        gdb_execute_monitor (command.mname + " " + format_fn(eval_arg_str), from_tty)
    elif arg_opt:
        gdb_execute_monitor (command.mname, from_tty)
    else:
        raise gdb.GdbError(('Argument "' + arg_descr + '" required.\n'
                            + build_type_help(command)))

def eval_execute_2(command : Valgrind_Command,
                   arg_str : str,
                   arg1_opt : bool, arg1_descr : str, format_fn1,
                   arg2_opt : bool, arg2_descr : str, format_fn2,
                   from_tty : bool) -> None:
    """Like eval_execute but allowing 2 arguments to be extracted from ARG_STR).
The second argument starts after the first space in ARG_STR."""
    if arg1_opt and not arg2_opt:
        raise gdb.GdbError(('Cannot have arg1_opt True and arg2_opt False'
                            + ' in definition of '
                            + build_name(command)))
    if arg_str:
        arg_str_v = arg_str.split(' ', 1);
        eval_arg1_str = gdb.parse_and_eval (arg_str_v[0])
        if len(arg_str_v) <= 1:
            if arg2_opt:
                gdb_execute_monitor (command.mname + " " + format_fn1(eval_arg1_str), from_tty)
            else:
                raise gdb.GdbError(('Argument 2 "' + arg2_descr + '" required.\n'
                                    + build_type_help(command)))
        else:
            eval_arg2_str = gdb.parse_and_eval (arg_str_v[1])
            gdb_execute_monitor (command.mname
                                 + " " + format_fn1(eval_arg1_str)
                                 + " " + format_fn1(eval_arg2_str),
                                 from_tty)
    elif arg1_opt and arg2_opt:
        gdb_execute_monitor (command.mname, from_tty)
    else:
        raise gdb.GdbError(('Argument 1 "' + arg1_descr + '" required.\n'
                            + ('' if arg2_opt
                               else 'Argument 2 "' + arg2_descr + '" required.\n')
                            + build_type_help(command)))

def def_alias(alias : str, command_name : str) -> None:
    """Defines an alias ALIAS = COMMAND_NAME.
Traps the error if ALIAS is already defined (so as to be able to source
this file again)."""
    d = "alias " + alias + ' = ' + command_name
    try:
        gdb.execute (d)
    except Exception as inst:
        print('"' + d + '" : '+ str(inst))

class Valgrind_ADDR(Valgrind_Command):
    """Common class for Valgrind commands taking ADDR arg."""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        eval_execute(self, arg_str,
                     False, "ADDR (address expression)", hex,
                     from_tty)
    
class Valgrind_ADDR_opt(Valgrind_Command):
    """Common class for Valgrind commands taking [ADDR] arg."""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        eval_execute(self, arg_str,
                     True, "ADDR (address expression)", hex,
                     from_tty)
    
class Valgrind_ADDR_LEN_opt(Valgrind_Command):
    """Common class for Valgrind commands taking ADDR and [LEN] args.
For compatibility reason with the Valgrind gdbserver monitor command,
we detect and accept usages such as 0x1234ABCD[10]."""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        if re.fullmatch("^0x[0123456789ABCDEFabcdef]+\[[^\[\]]+\]$", arg_str):
            arg_str = arg_str.replace("[", " ")
            arg_str = arg_str.replace("]", " ")
        eval_execute_2(self, arg_str,
                       False, "ADDR (address expression)", hex,
                       True, "LEN (integer length expression)", str,
                       from_tty)
    
############# The rest of this file defines first the valgrind general commands
# then the tool specific commands.
# The commands are defined in the same order as produced by
#   (gdb) monitor help debug

############# valgrind general commands.

###### Top of the hierarchy of the valgrind general commands.
@Vinit("valgrind", "", gdb.COMMAND_SUPPORT, gdb.COMPLETE_COMMAND, True)
class Valgrind_Monitor_Command(Valgrind_Prefix_Command):
    """Front end GDB command for Valgrind gdbserver monitor commands.
Usage: valgrind VALGRIND_MONITOR_COMMAND [ARG...]
VALGRIND_MONITOR_COMMAND is a valgrind subcommand, matching a
gdbserver Valgrind monitor command.
ARG... are optional arguments.  They depend on the VALGRIND_MONITOR_COMMAND.)

Type "help memcheck" or "help mc" for memcheck specific commands.
Type "help helgrind" or "help hg" for helgrind specific commands.
Type "help callgrind" or "help cg" for callgrind specific commands.
Type "help massif" or "help ms" for massif specific commands.
"""

def_alias("vg", "valgrind")
def_alias("v", "valgrind") # To avoid 'v' reported as ambiguous for 'vg' and 'valgrind' !

@Vinit("valgrind", "help", gdb.COMMAND_SUPPORT, gdb.COMPLETE_COMMAND, True)
class Valgrind_Help_Command(Valgrind_Prefix_Exec_Command):
    """Ask Valgrind gdbserver to output the help for its monitor commands.
Usage: valgrind help
This shows the help string reported by the Valgrind gdbserver.
Type "help valgrind" to get help about the GDB front end commands interfacing
to the Valgrind gdbserver monitor commands.
"""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        """Invoke for a prefix command that can be executed."""
        if arg_str:
            super().invoke(arg_str, from_tty)
        else:
            gdb_execute_monitor (self.mname, from_tty)

@Vinit("valgrind", "help debug", gdb.COMMAND_SUPPORT, gdb.COMPLETE_NONE, False)
class Valgrind_Help_Debug_Command(Valgrind_Command):
    """Ask Valgrind gdbserver to output the help for its monitor commands (including debugging commands).
Usage: valgrind help debug
This shows the help string reported by the Valgrind gdbserver.
Type "help valgrind" to get help about the GDB front end commands interfacing
to the Valgrind gdbserver monitor commands.
"""

@Vinit("valgrind", "v.wait", gdb.COMMAND_OBSCURE, gdb.COMPLETE_EXPRESSION, False)
class Valgrind_Wait_Command(Valgrind_Command):
    """Have Valgrind gdbserver sleeping for MS (default 0) milliseconds.
Usage: valgrind v.wait [MS]
MS is an integer expression evaluated by GDB.
"""
    def invoke(self, arg_str : str, from_tty: bool) -> None:
        eval_execute(self, arg_str,
                     True, "MS (integer expression in milliseconds)", str,
                     from_tty)

@Vinit("valgrind", "v.info", gdb.COMMAND_STATUS, gdb.COMPLETE_COMMAND, True)
class Valgrind_Info_Command(Valgrind_Prefix_Command):
    """Get various information about Valgrind gdbserver.
Usage: valgrind v.info WHAT [ARG...]
WHAT is the v.info subcommand, specifying the type of information requested.
ARG are optional arguments, depending on the WHAT subcommand.
"""

@Vinit("valgrind", "v.info all_errors", gdb.COMMAND_STATUS, gdb.COMPLETE_NONE, False)
class Valgrind_Info_All_Errors_Command(Valgrind_Command):
    """Show all errors found so far by Valgrind.
Usage: valgrind v.info all_errors
"""

@Vinit("valgrind", "v.info last_error", gdb.COMMAND_STATUS, gdb.COMPLETE_NONE, False)
class Valgrind_Info_Last_Error_Command(Valgrind_Command):
    """Show last error found by Valgrind.
Usage: valgrind v.info last_error
"""

@Vinit("valgrind", "v.info location", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Valgrind_Info_Location_Command(Valgrind_ADDR):
    """Show information known by Valgrind about location ADDR.
Usage: valgrind v.info location ADDR
ADDR is an address expression evaluated by GDB.
"""

@Vinit("valgrind", "v.info n_errs_found", gdb.COMMAND_STATUS, gdb.COMPLETE_NONE, False)
class Valgrind_Info_N_Errs_Found_Command(Valgrind_Command):
    """Show the nr of errors found so far by Valgrind and the given MSG.
Usage: valgrind v.info n_errs_found [MSG]
The optional MSG is made of all what follows n_errs_found and is not evaluated.
"""

@Vinit("valgrind", "v.info open_fds", gdb.COMMAND_DATA, gdb.COMPLETE_NONE, False)
class Valgrind_Info_Open_Fds_Command(Valgrind_Command):
    """Show open file descriptors tracked by Valgrind (only if --track-fds=yes).
Usage: valgrind v.info open_fds
"""

@Vinit("valgrind", "v.kill", gdb.COMMAND_RUNNING, gdb.COMPLETE_NONE, False)
class Valgrind_Kill_Command(Valgrind_Command):
    """Instruct valgrind gdbserver to kill the valgrind process.
Usage: valgrind v.kill
"""

@Vinit("valgrind", "v.clo", gdb.COMMAND_RUNNING, gdb.COMPLETE_NONE, False)
class Valgrind_Clo_Command(Valgrind_Command):
    """Change one or more Valgrind dynamic command line options.
Usage: valgrind v.clo [VALGRIND_OPTION]...
VALGRIND_OPTION is the command line option to change.
Example:   (gdb) valgrind v.clo --stats=yes --show-below-main=yes

Without VALGRIND_OPTION, shows the dynamically changeable options.
"""

@Vinit("valgrind", "v.set", gdb.COMMAND_STATUS, gdb.COMPLETE_COMMAND, True)
class Valgrind_Set_Command(Valgrind_Prefix_Command):
    """Modify various setting of Valgrind gdbserver.
Usage: valgrind v.set WHAT [ARG]...
WHAT is the v.set subcommand, specifying the setting to change.
ARG are optional arguments, depending on the WHAT subcommand.
"""

@Vinit("valgrind", "v.set gdb_output", gdb.COMMAND_STATUS, gdb.COMPLETE_NONE, False)
class Valgrind_Set_Gdb_Output_Command(Valgrind_Command):
    """Set Valgrind output to gdb.
Usage: valgrind v.set gdb_output
"""

@Vinit("valgrind", "v.set log_output", gdb.COMMAND_STATUS, gdb.COMPLETE_NONE, False)
class Valgrind_Set_Log_Output_Command(Valgrind_Command):
    """Set Valgrind output to Valgrind log.
Usage: valgrind v.set log_output
"""

@Vinit("valgrind", "v.set mixed_output", gdb.COMMAND_STATUS, gdb.COMPLETE_NONE, False)
class Valgrind_Set_Mixed_Output_Command(Valgrind_Command):
    """Set Valgrind output to Valgrind log, interactive output to gdb.
Usage: valgrind v.set mixed_output
"""

@Vinit("valgrind", "v.set merge-recursive-frames", gdb.COMMAND_STATUS, gdb.COMPLETE_EXPRESSION, False)
class Valgrind_Set_Merge_Recursive_Frames_Command(Valgrind_Command):
    """Set the number of frames for recursive calls merging in Valgrind stacktraces.
Usage: valgrind v.set merge-recursive-frames NUM
NUM is an integer expression evaluated by GDB.
"""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        eval_execute(self, arg_str, 
                     False, "NUM (number of frames for recursive calls merging)",
                     str,
                     from_tty)

@Vinit("valgrind", "v.set vgdb-error", gdb.COMMAND_RUNNING, gdb.COMPLETE_EXPRESSION, False)
class Valgrind_Set_Vgdb_Error_Command(Valgrind_Command):
    """Set the number of errors at which Valgrind gdbserver gives control to gdb.
Usage: valgrind v.set vgdb-error NUM
NUM is an integer expression evaluated by GDB.
"""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        eval_execute(self, arg_str,
                     False, "NUM (number of errors)",
                     str,
                     from_tty)

@Vinit("valgrind", "v.do", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_COMMAND, True)
class Valgrind_Do_Command(Valgrind_Prefix_Command):
    """Ask Valgrind gdbserver to do an internal/maintenance action.
Usage: valgrind v.do WHAT
WHAT is the valgrind v.do subcommand, specifying the type of action requested.
"""

@Vinit("valgrind", "v.do expensive_sanity_check_general", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_NONE, False)
class Valgrind_Do_Expensive_Sanity_Check_General_Command(Valgrind_Command):
    """Do an expensive Valgrind sanity check now.
Usage: valgrind v.do expensive_sanity_check_general
"""

@Vinit("valgrind", "v.info gdbserver_status", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_NONE, False)
class Valgrind_Info_Gdbserver_Status_Command(Valgrind_Command):
    """Show gdbserver status.
Usage: valgrind v.info gdbserver_status
"""

@Vinit("valgrind", "v.info memory", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_COMMAND, True)
class Valgrind_Info_Memory_Status_Command(Valgrind_Prefix_Exec_Command):
    """Show valgrind heap memory stats.
Usage: valgrind v.info memory
"""

@Vinit("valgrind", "v.info memory aspacemgr", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_NONE, False)
class Valgrind_Info_Memory_Aspacemgr_Command(Valgrind_Command):
    """Show Valgrind heap memory stats and show Valgrind segments on log output.
Usage: valgrind v.info memory aspacemgr
"""

@Vinit("valgrind", "v.info exectxt", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_NONE, False)
class Valgrind_Info_Exectxt_Command(Valgrind_Command):
    """Show stacktraces and stats of all execontexts record by Valgrind.
Usage: valgrind v.info exectxt
"""

@Vinit("valgrind", "v.info scheduler", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_NONE, False)
class Valgrind_Info_Scheduler_Command(Valgrind_Command):
    """Show Valgrind thread state and stacktrace.
Usage: valgrind v.info scheduler
"""

@Vinit("valgrind", "v.info stats", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_NONE, False)
class Valgrind_Info_Stats_Command(Valgrind_Command):
    """Show various Valgrind and tool stats.
Usage: valgrind v.info stats
"""

@Vinit("valgrind", "v.info unwind", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_EXPRESSION, False)
class Valgrind_Info_Unwind_Command(Valgrind_ADDR_LEN_opt):
    """Show unwind debug info for ADDR .. ADDR+LEN.
Usage: valgrind v.info unwind ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.
"""

@Vinit("valgrind", "v.set debuglog", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_EXPRESSION, False)
class Valgrind_Set_Debuglog_Command(Valgrind_Command):
    """Set Valgrind debug log level to LEVEL.
Usage: valgrind v.set LEVEL
LEVEL is an integer expression evaluated by GDB.
"""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        eval_execute(self, arg_str, 
                     False, "LEVEL (valgrind debug log level)",
                     str,
                     from_tty)
@Vinit("valgrind", "v.set hostvisibility", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_COMMAND, True)
class Valgrind_Set_Hostvisibility_Command(Valgrind_Prefix_Exec_Command):
    """Set visibility of the internal Valgrind 'host' state.
Without arguments, enables the host visibility.
Host visibility allows to examine with GDB the internal status and memory
of Valgrind.
Usage: valgrind v.set hostvisibility
"""

@Vinit("valgrind", "v.set hostvisibility yes", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_NONE, False)
class Valgrind_Set_Hostvisibility_Yes_Command(Valgrind_Command):
    """Enable visibility of the internal Valgrind 'host' state.
Usage: valgrind v.set hostvisibility yes
See "help v.set hostvisibility".
"""

@Vinit("valgrind", "v.set hostvisibility no", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_NONE, False)
class Valgrind_Set_Hostvisibility_No_Command(Valgrind_Command):
    """Disable visibility of the internal Valgrind 'host' state.
Usage: valgrind v.set hostvisibility no
See "help v.set hostvisibility".
"""

def base2(value : int) -> str:
    """Image of value in base 2 prefixed with 0b."""
    "0b" + "{0:b}".format(value)

@Vinit("valgrind", "v.translate", gdb.COMMAND_MAINTENANCE, gdb.COMPLETE_EXPRESSION, False)
class Valgrind_Translate_Command(Valgrind_Command):
    """Show the translation of instructions at ADDR with TRACEFLAGS.
Usage: valgrind v.translate ADDR [TRACEFLAG]
For TRACEFLAG values, type in shell "valgrind --help-debug".
An additional flag  0b100000000 allows one to show gdbserver instrumentation.
ADDR is an address expression evaluated by GDB.
TRACEFLAG is an integer expression (used as a bitmask) evaluated by GDB.
"""
    def invoke(self, arg_str : str, from_tty : bool) -> None:
        eval_execute_2(self, arg_str,
                       False, "ADDR (address expression)", hex,
                       True, "TRACEFLAGS (bit mask expression)", base2,
                       from_tty)

############# memcheck commands.

######  Top of the hierarchy of the memcheck commands.
@Vinit("memcheck", "", gdb.COMMAND_SUPPORT, gdb.COMPLETE_COMMAND, True)
class Memcheck_Command(Valgrind_Prefix_Command):
    """Front end GDB command for Valgrind memcheck gdbserver monitor commands.
Usage: memcheck MEMCHECK_MONITOR_COMMAND [ARG...]
MEMCHECK_MONITOR_COMMAND is a memcheck subcommand, matching 
a gdbserver Valgrind memcheck monitor command.
ARG... are optional arguments.  They depend on the MEMCHECK_MONITOR_COMMAND.
"""
    
def_alias("mc", "memcheck")

@Vinit("memcheck", "xtmemory", gdb.COMMAND_DATA, gdb.COMPLETE_FILENAME, False)
class Memcheck_Xtmemory_Command(Valgrind_Command):
    """Dump xtree memory profile in FILENAME (default xtmemory.kcg.%p.%n).
Usage: memcheck xtmemory [FILENAME]

Example:   (gdb) memcheck xtmemory my_program_xtree.kcg
"""

@Vinit("memcheck", "xb", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Xb_Command(Valgrind_ADDR_LEN_opt):
    """Print validity bits for LEN (default 1) bytes at ADDR.
            bit values 0 = valid, 1 = invalid, __ = unaddressable byte
Prints the bytes values below the corresponding validity bits
in a layout similar to the gdb command 'x /LENxb ADDR
Usage: memcheck xb ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) memcheck xb &p sizeof(p)
"""

@Vinit("memcheck", "get_vbits", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Get_Vbits_Command(Valgrind_ADDR_LEN_opt):
    """Print validity bits for LEN (default 1) bytes at ADDR.
            bit values 0 = valid, 1 = invalid, __ = unaddressable byte
Usage: memcheck get_vbits ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) memcheck get_vbits &p sizeof(p)

Note: the command 'memcheck xb ADDR [LEN]' prints the value 
and validity bits of ADDR [LEN] bytes in an easier to read format.
"""

@Vinit("memcheck", "make_memory", gdb.COMMAND_DATA, gdb.COMPLETE_COMMAND, True)
class Memcheck_Make_Memory_Command(Valgrind_Prefix_Command):
    """Prefix command to change memory accessibility."""

@Vinit("memcheck", "make_memory noaccess", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Make_Memory_Noaccess_Command(Valgrind_ADDR_LEN_opt):
    """Mark LEN (default 1) bytes at ADDR as noaccess.
Usage: memcheck make_memory noaccess ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) memcheck make_memory noaccess &p sizeof(p)
"""

@Vinit("memcheck", "make_memory undefined", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Make_Memory_Undefined_Command(Valgrind_ADDR_LEN_opt):
    """Mark LEN (default 1) bytes at ADDR as undefined.
Usage: memcheck make_memory undefined ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) memcheck make_memory undefined &p sizeof(p)
"""

@Vinit("memcheck", "make_memory defined", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Make_Memory_Defined_Command(Valgrind_ADDR_LEN_opt):
    """Mark LEN (default 1) bytes at ADDR as defined.
Usage: memcheck make_memory defined ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) memcheck make_memory defined &p sizeof(p)
"""

@Vinit("memcheck", "make_memory Definedifaddressable", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Make_Memory_Definedifaddressable_Command(Valgrind_ADDR_LEN_opt):
    """Mark LEN (default 1) bytes at ADDR as Definedifaddressable.
Usage: memcheck make_memory Definedifaddressable ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) memcheck make_memory Definedifaddressable &p sizeof(p)
"""

@Vinit("memcheck", "check_memory", gdb.COMMAND_DATA, gdb.COMPLETE_COMMAND, True)
class Memcheck_Check_Memory_Command(Valgrind_Prefix_Command):
    """Command to check memory accessibility."""

@Vinit("memcheck", "check_memory addressable", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Check_Memory_Addressable_Command(Valgrind_ADDR_LEN_opt):
    """Check that LEN (default 1) bytes at ADDR are addressable.
Usage: memcheck check_memory addressable ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) memcheck check_memory addressable &p sizeof(p)
"""

@Vinit("memcheck", "check_memory defined", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Check_Memory_Defined_Command(Valgrind_ADDR_LEN_opt):
    """Check that LEN (default 1) bytes at ADDR are defined.
Usage: memcheck check_memory defined ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) memcheck check_memory defined &p sizeof(p)
"""

@Vinit("memcheck", "leak_check", gdb.COMMAND_DATA, gdb.COMPLETE_NONE, False)
class Memcheck_Leak_Check_Command(Valgrind_Command):
    """Execute a memcheck leak search.
Usage: leak_check [full*|summary|xtleak]
                [kinds KIND1,KIND2,...|reachable|possibleleak*|definiteleak]
                [heuristics HEUR1,HEUR2,...]
                [new|increased*|changed|any]
                [unlimited*|limited MAX_LOSS_RECORDS_OUTPUT]
            * = defaults

full:    outputs stacktraces of all leaks followed by a summary.
summary: outputs only the leak summary.
xtleak:  produce an xtree full leak result in xtleak.kcg.%p.%n

KIND indicates which kind of leaks to report, and is one of:
    definite indirect possible reachable all none

HEUR indicates an heuristic to activate when doing leak search and is one of:
    stdstring length64 newarray multipleinheritance all none*

new:       only outputs the new leak loss records since last leak search.
increased: only outputs the leak loss records with an increase since 
              last leak search.
changed:   also outputs the leak loss records with a decrease.
any:       also outputs the leak loss records that did not change.

unlimited: outputs all matching loss records.
limited:   outputs only the first matching MAX_LOSS_RECORDS_OUTPUT.

This command auto-completes the user input by providing the full list of
keywords still relevant according to what is already typed. For example, if the
"summary" keyword has been provided, the following TABs to auto-complete other
items will not propose anymore "full" and "xtleak".  Note that KIND and HEUR
values are not part of auto-completed elements.

Examples:   (gdb) memcheck leak_check
            (gdb) memcheck leak_check summary any
            (gdb) memcheck leak_check full kinds indirect,possible
            (gdb) memcheck leak_check full reachable any limited 100

    """

    def complete(self, text, word):
        # print('/' + text + ' ' + word + '/\n')
        leak_check_mode = ["full", "summary", "xtleak"]
        leak_kind = ["kinds", "reachable", "possibleleak", "definiteleak"]
        leak_heuristic = ["heuristics"]
        leak_check_delta_mode = ["new", "increased", "changed", "any"]
        leak_check_loss_record_limit = ["unlimited", "limited"]
        kwd_lists = [leak_check_mode, leak_kind, leak_heuristic,
                     leak_check_delta_mode, leak_check_loss_record_limit]
        # Build the list of still allowed keywords.
        # We append all the keywords of a list unless we find already one
        # existing word in text that starts with the first letter of a keyword
        # of the list. Checking the first letter is ok (currently!)
        # as all keywords of leak_check monitor command starts with a different
        # letter.
        keywords = []
        command_words = text.split()
        for kwd_list in kwd_lists:
            list_ok = True
            # print('list:/' + str(kwd_list) + '/')
            for kwd in kwd_list:
                for command_word in command_words:
                    # print('word:/' + command_word + '/' + kwd)
                    if kwd[0] == command_word[0]:
                        # print("setting to false")
                        list_ok = False
                        if (kwd.startswith(word) and
                            word != kwd
                            and kwd not in command_words
                            ):
                            # print('/' + word + '/' + kwd + '/')
                            keywords.append(kwd)
            if list_ok:
                for kwd in kwd_list:
                    keywords.append(kwd)
        result = []
        for keyword in keywords:
            if keyword.startswith(word):
                result.append(keyword)
        return result

@Vinit("memcheck", "block_list", gdb.COMMAND_DATA, gdb.COMPLETE_NONE, False)
class Memcheck_Block_List_Command(Valgrind_Command):
    """Show the list of blocks for a leak search loss record.
Usage: memcheck block_list LOSS_RECORD_NR|LOSS_RECORD_NR_FROM..LOSS_RECORD_NR_TO
                unlimited*|limited MAX_BLOCKS
                [heuristics HEUR1,HEUR2,...]
            * = defaults

After a leak search, use block_list to show the list of blocks matching a loss
record or matching a range of loss records.

unlimited: outputs all blocks matching the selected loss records.
limited:   outputs only the first matching MAX_BLOCKS.

Use heuristics to only output the blocks found via one of the given heuristics,
where HEUR is one of:
    stdstring length64 newarray multipleinheritance all none*
    """

@Vinit("memcheck", "who_points_at", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Memcheck_Who_Points_At_Command(Valgrind_ADDR_LEN_opt):
    """Show places pointing inside LEN (default 1) bytes at ADDR.
Usage: memcheck who_points_at ADDR [LEN]
With LEN 1, only shows "start pointers" pointing exactly to ADDR.
With LEN > 1, will also show "interior pointers"
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.
"""

############# helgrind commands.

######  Top of the hierarchy of the helgrind commands.
@Vinit("helgrind", "", gdb.COMMAND_SUPPORT, gdb.COMPLETE_COMMAND, True)
class Helgrind_Command(Valgrind_Prefix_Command):
    """Front end GDB command for Valgrind helgrind gdbserver monitor commands.
Usage: helgrind HELGRIND_MONITOR_COMMAND [ARG...]
HELGRIND_MONITOR_COMMAND is a helgrind subcommand, matching 
a gdbserver Valgrind helgrind monitor command.
ARG... are optional arguments.  They depend on the HELGRIND_MONITOR_COMMAND.
"""
    
def_alias("hg", "helgrind")

@Vinit("helgrind", "info", gdb.COMMAND_STATUS, gdb.COMPLETE_COMMAND, True)
class Helgrind_Info_Command(Valgrind_Prefix_Command):
    """Get various information about helgrind tool status.
Usage: helgrind info WHAT
WHAT is the helgrind info subcommand, specifying the type of information requested.
"""

@Vinit("helgrind", "info locks", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Helgrind_Info_Locks_Command(Valgrind_ADDR_opt):
    """Show the status of one or all locks recorded by helgrind.
Usage: helgrind info locks [ADDR]
ADDR is an address expression evaluated by GDB.
When ADDR is provided, shows the status of the lock located at ADDR,
otherwise shows the status of all locks.
"""

@Vinit("helgrind", "accesshistory", gdb.COMMAND_DATA, gdb.COMPLETE_EXPRESSION, False)
class Helgrind_Accesshistory_Command(Valgrind_ADDR_LEN_opt):
    """Show access history recorded for LEN (default 1) bytes at ADDR.
Usage: helgrind accesshistory ADDR [LEN]
ADDR is an address expression evaluated by GDB.
LEN is an integer expression evaluated by GDB.

Example:   (gdb) helgrind accesshistory &p sizeof(p)
"""

@Vinit("helgrind", "xtmemory", gdb.COMMAND_DATA, gdb.COMPLETE_FILENAME, False)
class Helgrind_Xtmemory_Command(Valgrind_Command):
    """Dump xtree memory profile in FILENAME (default xtmemory.kcg.%p.%n).
Usage: helgrind xtmemory [FILENAME]

Example:   (gdb) helgrind xtmemory my_program_xtree.kcg
"""

############# callgrind commands.

######  Top of the hierarchy of the callgrind commands.
@Vinit("callgrind", "", gdb.COMMAND_SUPPORT, gdb.COMPLETE_COMMAND, True)
class Callgrind_Command(Valgrind_Prefix_Command):
    """Front end GDB command for Valgrind callgrind gdbserver monitor commands.
Usage: callgrind CALLGRIND_MONITOR_COMMAND [ARG...]
CALLGRIND_MONITOR_COMMAND is a callgrind subcommand, matching 
a gdbserver Valgrind callgrind monitor command.
ARG... are optional arguments.  They depend on the CALLGRIND_MONITOR_COMMAND.
"""
    
def_alias("cg", "callgrind")

@Vinit("callgrind", "dump", gdb.COMMAND_DATA, gdb.COMPLETE_COMMAND, False)
class Callgrind_Dump_Command(Valgrind_Command):
    """Dump the callgrind counters.
Usage: callgrind dump [DUMP_HINT]
DUMP_HINT is a message stored in the resulting callgrind dump file.
"""

@Vinit("callgrind", "zero", gdb.COMMAND_DATA, gdb.COMPLETE_COMMAND, False)
class Callgrind_Zero_Command(Valgrind_Command):
    """Set the callgrind counters to zero.
Usage: callgrind zero
"""

@Vinit("callgrind", "status", gdb.COMMAND_STATUS, gdb.COMPLETE_NONE, False)
class Callgrind_Status_Command(Valgrind_Command):
    """Show the status of callgrind.
Usage: callgrind status
"""
    
@Vinit("callgrind", "instrumentation", gdb.COMMAND_STATUS, gdb.COMPLETE_COMMAND, False)
class Callgrind_Instrumentation_Command(Valgrind_Command):
    """Get or set the callgrind instrumentation state.
Usage: callgrind instrumentation [on|off]
Without argument, shows the current state of instrumentation,
otherwise changes the instrumentation state to the given argument.
"""

############# massif commands.

######  Top of the hierarchy of the massif commands.
@Vinit("massif", "", gdb.COMMAND_SUPPORT, gdb.COMPLETE_COMMAND, True)
class Massif_Command(Valgrind_Prefix_Command):
    """Front end GDB command for Valgrind massif gdbserver monitor commands.
Usage: massif MASSIF_MONITOR_COMMAND [ARG...]
MASSIF_MONITOR_COMMAND is a massif subcommand, matching 
a gdbserver Valgrind massif monitor command.
ARG... are optional arguments.  They depend on the MASSIF_MONITOR_COMMAND.
"""

def_alias("ms", "massif")

@Vinit("massif", "snapshot", gdb.COMMAND_DATA, gdb.COMPLETE_FILENAME, False)
class Massif_Dump_Command(Valgrind_Command):
    """Take a massif snapshot in FILENAME (default massif.vgdb.out).
Usage: massif snapshot [FILENAME]
"""

@Vinit("massif", "detailed_snapshot", gdb.COMMAND_DATA, gdb.COMPLETE_FILENAME, False)
class Massif_Dump_Command(Valgrind_Command):
    """Take a massif detailed snapshot in FILENAME (default massif.vgdb.out).
Usage: massif detailed_snapshot [FILENAME]
"""

@Vinit("massif", "all_snapshots", gdb.COMMAND_DATA, gdb.COMPLETE_FILENAME, False)
class Massif_Dump_Command(Valgrind_Command):
    """Save all snapshot(s) taken so far in FILENAME (default massif.vgdb.out).
Usage: massif all_snapshots [FILENAME]
"""

@Vinit("massif", "xtmemory", gdb.COMMAND_DATA, gdb.COMPLETE_FILENAME, False)
class Massic_Xtmemory_Command(Valgrind_Command):
    """Dump xtree memory profile in FILENAME (default xtmemory.kcg.%p.%n).
Usage: massif xtmemory [FILENAME]

Example:   (gdb) massif xtmemory my_program_xtree.kcg
"""
