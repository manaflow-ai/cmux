"""Each hidden rig Mac app's own machine id (#24701).

Every cmux build on one Mac registers that Mac's machine id, so the phone lists
the computer once (MacRoster). Several hidden rig apps on one mini then fold into
one entry, and a rig can vanish behind another agent's. A DEBUG rig app passes
CMUX_NEXT_MOBILE_MACHINE_ID (32 hex digits) to cmux-mobile-host as its machine
id; this module derives one per rig folder and Mac, stable across launches.
"""
import hashlib
import os
import socket

KEY = "CMUX_NEXT_MOBILE_MACHINE_ID"


def machine_id(rig_dir, host=None):
    """32 hex digits from this Mac's name and the rig folder's real path."""
    host = host if host is not None else socket.gethostname()
    path = os.path.realpath(rig_dir.rstrip("/") or "/")
    return hashlib.sha256(f"cmux-rig-machine-id v1\0{host}\0{path}".encode()).hexdigest()[:32]


def launch_env(rig_dir, host=None):
    """The rig app's launch variable (passed with open --env)."""
    return {KEY: machine_id(rig_dir, host)}
