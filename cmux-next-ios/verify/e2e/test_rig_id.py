"""Unit tests for the rig machine id in mac.py (python3 -m unittest test_rig_id, from this folder)."""
import re
import unittest
from unittest import mock

import mac

UUID = "12345678-ABCD-4EF0-9876-0123456789AB"


class RigMachineIDTests(unittest.TestCase):
    def test_is_32_hex_digits_and_pinned(self):
        value = mac.rig_machine_id("com.cmuxterm.app.debug.rig.a", host_uuid=UUID)
        self.assertRegex(value, r"^[0-9a-f]{32}$")
        # Golden value: a change to the derivation would move every rig's Mac on the phone.
        self.assertEqual(value, "14c8d1c7737e2f3e894b84080a9156b3")

    def test_two_rig_apps_on_one_mac_differ(self):
        self.assertNotEqual(mac.rig_machine_id("com.cmuxterm.app.debug.rig.a", host_uuid=UUID),
                            mac.rig_machine_id("com.cmuxterm.app.debug.rig.b", host_uuid=UUID))

    def test_one_app_on_two_macs_differs(self):
        self.assertNotEqual(mac.rig_machine_id("com.cmuxterm.app.debug.rig.a", host_uuid=UUID),
                            mac.rig_machine_id("com.cmuxterm.app.debug.rig.a", host_uuid=UUID.replace("1", "2")))

    def test_hardware_uuid_reads_ioreg(self):
        out = '  "IOPlatformSerialNumber" = "X"\n  "IOPlatformUUID" = "%s"\n' % UUID.lower()
        with mock.patch.object(mac, "_HARDWARE_UUID", None), \
                mock.patch.object(mac.subprocess, "run", return_value=mock.Mock(stdout=out)):
            self.assertEqual(mac.hardware_uuid(), UUID)

    def _mac(self, own):
        m = mac.Mac("/tmp/rig", "/tmp/src/cmux DEV rig.app")
        m._bundle, m._tag = "com.cmuxterm.app.debug.rig.a", "rig"
        m.own_machine_id = own
        return m

    def test_rig_env_carries_it_and_a_harness_can_turn_it_off(self):
        with mock.patch.object(mac, "hardware_uuid", return_value=UUID):
            self.assertEqual(self._mac(True).rig_env()[mac.RIG_MACHINE_ID_KEY],
                             mac.rig_machine_id("com.cmuxterm.app.debug.rig.a", host_uuid=UUID))
            self.assertNotIn(mac.RIG_MACHINE_ID_KEY, self._mac(False).rig_env())
            with mock.patch.dict(mac.os.environ, {"CMUX_RIG_SHARED_MACHINE_ID": "1"}):
                self.assertNotIn(mac.RIG_MACHINE_ID_KEY, self._mac(True).rig_env())


if __name__ == "__main__":
    unittest.main()
