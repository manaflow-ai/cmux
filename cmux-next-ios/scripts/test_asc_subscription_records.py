"""plan_for reads a promotional image's own state, so a finished image is left alone.

Run: python3 -I -m unittest cmux-next-ios/scripts/test_asc_subscription_records.py
(from the repo root), or python3 -I this file.
"""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
_spec = importlib.util.spec_from_file_location("asc_subscription_records", HERE / "asc_subscription_records.py")
records = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(records)

LISTED = {"reviewScreenshot": "shot.png", "promotionalImage": "promo.png"}


def state(images, shot_state="COMPLETE"):
    return {
        "id": "1", "state": "READY_TO_SUBMIT",
        "reviewScreenshot": {"id": "s", "attributes": {"assetDeliveryState": {"state": shot_state}}},
        "images": images, "locales": set(), "hasPrice": True, "hasAvailability": True,
    }


class PlanForImages(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for name in LISTED.values():
            (self.root / name).write_bytes(b"png")

    def tearDown(self):
        self.tmp.cleanup()

    def kinds(self, st):
        writes, _, _ = records.plan_for(LISTED, st, self.root)
        return [w["kind"] for w in writes]

    def test_image_with_its_own_finished_state_is_left_alone(self):
        for done in ("UPLOAD_COMPLETE", "PREPARE_FOR_SUBMISSION", "WAITING_FOR_REVIEW", "APPROVED"):
            with self.subTest(done=done):
                self.assertEqual(self.kinds(state([{"id": "i", "attributes": {"state": done}}])), [])

    def test_image_awaiting_or_failed_is_replaced(self):
        for stuck in ("AWAITING_UPLOAD", "FAILED", "REJECTED", None):
            with self.subTest(stuck=stuck):
                writes, _, _ = records.plan_for(LISTED, state([{"id": "i", "attributes": {"state": stuck}}]), self.root)
                self.assertEqual([w["kind"] for w in writes], ["promotionalImage"])
                self.assertEqual(writes[0]["replace"][0]["id"], "i")

    def test_screenshot_still_reads_asset_delivery_state(self):
        image = [{"id": "i", "attributes": {"state": "APPROVED"}}]
        self.assertEqual(self.kinds(state(image, shot_state="UPLOAD_COMPLETE")), [])
        self.assertEqual(self.kinds(state(image, shot_state="AWAITING_UPLOAD")), ["reviewScreenshot"])

    def test_no_image_is_uploaded(self):
        self.assertEqual(self.kinds(state([])), ["promotionalImage"])


if __name__ == "__main__":
    unittest.main()
