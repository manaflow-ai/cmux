import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextPalette
import Observation

/// The palette's rows that predict a Chromium tab (ChromiumWarmup) while WebKit is the default
/// engine: its Chromium entries. Selecting or hovering one starts Chromium at the next idle
/// moment (with Chromium the default, the launch warm start already did).
@MainActor
struct ChromiumPaletteSignal {
    static let chromiumRows: Set<String> = ["action:openBrowser.chromium", "action:browser.openInChromium"]

    /// Watches `model` until a likely row is selected or hovered.
    static func observe(_ model: PaletteModel, warmup: ChromiumWarmup) -> Task<Void, Never> {
        Task { [weak warmup] in
            for await rows in ObservationStream({ [model.selectedRowID, model.hoveredRowID] }) {
                guard rows.contains(where: { $0.map(chromiumRows.contains) ?? false }) else { continue }
                warmup?.chromiumLikely(.palette)
                return
            }
        }
    }
}
