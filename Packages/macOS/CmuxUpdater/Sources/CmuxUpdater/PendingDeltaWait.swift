import Foundation
@preconcurrency import Sparkle

/// Holds back, for one scheduled check, an update whose Sparkle deltas may still be coming.
///
/// The nightly-next pipeline lists a build's full DMG first and its deltas some minutes later
/// (`generate-nightly-deltas` in `nightly.yml`). A Mac that checks in between would download
/// the full DMG (221 MB) although a delta of a few MB is close. A fresh update that lists no
/// deltas is therefore skipped once; the next scheduled check takes the update whether or not
/// deltas arrived, so the wait never exceeds one check interval and never repeats.
struct PendingDeltaWait {
    /// How long after its `pubDate` an update without deltas is held back.
    let window: TimeInterval
    /// Whether the previous scheduled check was held back; the next one never is.
    private var heldPreviousCheck = false

    init(window: TimeInterval) {
        self.window = window
    }

    /// Returns whether a scheduled check should skip `item` and leave it to the next check.
    mutating func shouldHold(_ item: SUAppcastItem, now: Date) -> Bool {
        if heldPreviousCheck {
            heldPreviousCheck = false
            return false
        }
        guard item.deltaUpdates?.isEmpty ?? true, let published = item.date,
              abs(now.timeIntervalSince(published)) < window else { return false }
        heldPreviousCheck = true
        return true
    }
}
