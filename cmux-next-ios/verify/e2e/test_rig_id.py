"""Unit tests for rig_id (python3 -m unittest test_rig_id, from this folder)."""
import os
import re
import tempfile
import unittest

import rig_id


class RigMachineIDTests(unittest.TestCase):
    def test_is_32_hex_digits(self):
        self.assertRegex(rig_id.machine_id("/tmp/rig-a"), r"^[0-9a-f]{32}$")

    def test_two_rigs_on_one_mac_differ(self):
        # Several hidden rig apps on one mini must be listed apart on the phone.
        self.assertNotEqual(rig_id.machine_id("/Users/cmux/rigs/a"), rig_id.machine_id("/Users/cmux/rigs/b"))

    def test_one_rig_keeps_its_id(self):
        # Stable across launches, so the phone's paired Mac stays the same.
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(rig_id.machine_id(d), rig_id.machine_id(d + "/"))
            link = d + "-link"
            os.symlink(d, link)
            try:
                self.assertEqual(rig_id.machine_id(d), rig_id.machine_id(link))
            finally:
                os.unlink(link)

    def test_the_same_folder_on_two_macs_differs(self):
        self.assertNotEqual(rig_id.machine_id("/Users/cmux/rig", host="mini-a"),
                            rig_id.machine_id("/Users/cmux/rig", host="mini-b"))

    def test_launch_env_names_the_app_knob(self):
        env = rig_id.launch_env("/tmp/rig-a")
        self.assertEqual(list(env), ["CMUX_NEXT_MOBILE_MACHINE_ID"])
        self.assertTrue(re.fullmatch(r"[0-9a-f]{32}", env["CMUX_NEXT_MOBILE_MACHINE_ID"]))


if __name__ == "__main__":
    unittest.main()
