"""rig.py with this rig's own machine id and name (a shared mini runs several rigs).

Lives next to a copy of multimac/rig.py in the rig folder (BASE: rig.py, src/<tagged app>,
repo/ -> a source tree, fake_agent.py). Same commands as rig.py; launch also passes
CMUX_NEXT_MOBILE_MACHINE_ID (BASE/MACHINE_ID, 32 hex digits, made once) so the phone does not
fold this rig into other agents' rigs on the same mini, and CMUX_NEXT_MOBILE_DEVICE_NAME
(MULTIMAC_DEVICE_NAME, default "hdralign-mac").

    python3 rig_hdr.py prepare|launch|quit|status|device-id|cli ARGS...|ask TEXT|acpmux ARGS...
"""
import os
import secrets
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
os.environ.setdefault("MULTIMAC_DEVICE_NAME", "hdralign-mac")
import rig  # noqa: E402

path = os.path.join(BASE, "MACHINE_ID")
if not os.path.exists(path):
    open(path, "w").write(secrets.token_hex(16) + "\n")
MACHINE_ID = open(path).read().strip()
_mac = rig.mac


def mac():
    m = _mac()
    m.launch_env = dict(m.launch_env, CMUX_NEXT_MOBILE_MACHINE_ID=MACHINE_ID)
    return m


rig.mac = mac
if __name__ == "__main__":
    rig.main()
