import unittest

from cmux import CmuxClient, ProtocolError


class ProtocolTests(unittest.TestCase):
    def test_attach_rejects_protocols_newer_than_seven_even_with_opt_in(self) -> None:
        client = CmuxClient.__new__(CmuxClient)
        client._protocol = 8
        client.allow_protocol_v6_attach = True

        with self.assertRaisesRegex(ProtocolError, "maximum supported is 7"):
            client.attach_surface(1)


if __name__ == "__main__":
    unittest.main()
