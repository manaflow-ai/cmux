#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""The notices tools need Python 3.11 or newer.

They read Cargo.lock and every crate's Cargo.toml with tomllib, which Python
3.11 added. A small parser cannot replace it: the manifests of third-party
crates use all of TOML. Under an older python3 (macOS's /usr/bin/python3 is
3.9.6) this module ends the run with one line that names the needed version
and the interpreter, in place of a traceback from `import tomllib`.

Each tool imports it before tomllib. The generator
(scripts/cmux-next/generate-third-party-notices.sh) runs it first, before any
download. Keep this file valid for every Python 3: an old one must be able to
read it.
"""

import os
import sys

if sys.version_info < (3, 11):
    sys.exit(
        "%s: needs Python 3.11 or newer (tomllib); python3 is Python %d.%d.%d at %s. "
        "Put a python3 that is 3.11 or newer first in PATH."
        % ((os.path.basename(sys.argv[0]) or "notices",) + tuple(sys.version_info[:3]) + (sys.executable,))
    )
