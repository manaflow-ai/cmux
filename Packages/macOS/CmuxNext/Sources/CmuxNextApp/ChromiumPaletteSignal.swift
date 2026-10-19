import CmuxNextCompat
import CmuxNextPalette
import CmuxNextSettings
import Observation

/// The palette's rows that predict a Chromium tab (ChromiumWarmup): its
/// Chromium entries and, while Chromium is the default engine, the entries
/// that open a tab on the default engine. Selecting or hovering one starts
/// Chromium at the next idle moment.
@MainActor
struct ChromiumPaletteSignal {
    static let chromiumRows: Set<String> = ["action:openBrowser.chromium", "action:browser.openInChromium"]
    /// Rows that open a tab on the default engine.
    static let defaultBrowserRows: Set<String> = [
        "action:openBrowser", "action:splitBrowserRight", "action:splitBrowserDown", "action:newBrowserWorkspace",
    ]

    /// Watches `model` until a likely row is selected or hovered.
    static func observe(_ model: PaletteModel, preference: BrowserEnginePreference, warmup: ChromiumWarmup) -> Task<Void, Never> {
        Task { [weak warmup] in
            for await rows in ObservationStream({ [model.selectedRowID, model.hoveredRowID] }) {
                let likely = chromiumRows.union(preference.defaultEngine == .chromium ? defaultBrowserRows : [])
                guard rows.contains(where: { $0.map(likely.contains) ?? false }) else { continue }
                warmup?.chromiumLikely(.palette)
                return
            }
        }
    }
}
