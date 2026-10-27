import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextPalette
import CmuxNextWakeups
import Observation

/// The palette's rows that predict a Chromium tab (ChromiumWarmup) while WebKit is the default
/// engine: its Chromium entries. Selecting or hovering one starts Chromium at the next idle
/// moment (with Chromium the default, the launch warm start already did).
@MainActor
final class ChromiumPaletteSignal {
    static let chromiumRows: Set<String> = ["action:openBrowser.chromium", "action:browser.openInChromium"]

    private var watch: ServiceObservation<[String?]>?

    /// Watches `model` until a likely row is selected or hovered; keep the signal while it watches. `background`: the
    /// warm start waits for an idle moment anyway. A second likely row asks again, which the warm-up ignores.
    init(_ model: PaletteModel, warmup: ChromiumWarmup, on mainWork: MainWorkScheduler) {
        watch = ServiceObservation(.background, owner: "ChromiumPaletteSignal", on: mainWork) {
            [model.selectedRowID, model.hoveredRowID]
        } apply: { [weak self, weak warmup] rows in
            guard rows.contains(where: { $0.map(Self.chromiumRows.contains) ?? false }) else { return }
            warmup?.chromiumLikely(.palette)
            self?.watch?.cancel()
        }
    }
}
