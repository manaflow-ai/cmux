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
Loads valgrind-monitor-def.py if not yet loaded.
The purpose of this file is to avoid re-defining the python commands
by reloading valgrind-monitor-def.py, as such redefinition causes a
segmentation violation in GDB <= 13.
"""

import os

if gdb.convenience_variable("valgrind_monitor_loaded") == None:
    gdb.execute("source " + os.path.dirname(__file__) + "/valgrind-monitor-def.py")
    gdb.set_convenience_variable ("valgrind_monitor_loaded", 1)
    print("Loaded "+  __file__)
    print("""Type "help valgrind" for more info.""")
