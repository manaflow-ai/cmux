#if canImport(UIKit) && DEBUG
import UIKit

/// DEBUG-only harness that proves the list stays glued to the composer during
/// an interactive keyboard dismiss. The composer itself tracks the keyboard
/// perfectly by construction (it is the input accessory), so the thing worth
/// measuring is OUR per-frame list-sync code: if it ever stops driving the
/// list inset while the composer moves (the exact regression that made the old
/// chat freeze), the recorded delta blows up to the full keyboard travel.
///
/// Each sampled frame compares the composer's real top (presentation layer,
/// screen space) against where the list's currently-applied bottom inset
/// implies the composer should be. A correctly-synced drag keeps this within a
/// frame's worth of travel; a frozen sync diverges immediately.
///
/// Results are published into a hidden element's `accessibilityValue` in the
/// repo's `key=value;` probe convention so an XCUITest can read max/mean/n
/// without any IPC.
@MainActor
final class ChatLabMetricsProbe {
    let probeView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "ChatLabTrackProbe"
        view.accessibilityValue = "max=0;mean=0;n=0"
        return view
    }()

    private var maxDelta: CGFloat = 0
    private var sumDelta: CGFloat = 0
    private var samples: Int = 0
    private var composerHeight: CGFloat = 0

    /// Begins a fresh measurement window (called when a drag starts).
    func reset() {
        maxDelta = 0
        sumDelta = 0
        samples = 0
        publish()
    }

    /// Records one frame's tracking delta.
    func record(composerTopScreen: CGFloat, listBottomScreen: CGFloat, appliedInset: CGFloat) {
        let expectedComposerTop = listBottomScreen - appliedInset
        let delta = abs(composerTopScreen - expectedComposerTop)
        maxDelta = max(maxDelta, delta)
        sumDelta += delta
        samples += 1
        publish()
    }

    func noteComposerHeight(_ height: CGFloat) {
        composerHeight = height
        publish()
    }

    private func publish() {
        let mean = samples == 0 ? 0 : sumDelta / CGFloat(samples)
        probeView.accessibilityValue = String(
            format: "max=%.2f;mean=%.2f;n=%d;composerHeight=%.1f",
            maxDelta, mean, samples, composerHeight
        )
    }
}
#endif
