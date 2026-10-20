import CmuxNextBrowser
import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTabs
import Observation

// When Chromium is likely (ChromiumWarmup): Chromium tabs, the palette's
// Chromium entries and, while Chromium is the default engine, any browser tab
// and the palette's default browser entries. The "+" engine menu reports from
// PaneController.contextMenu(for: .newTabButton), the default-engine action
// from SettingsHandlers.
extension AppServices {
    /// Starts the launch preload and the likelihood observers.
    func startChromiumWarmup() {
        let machines = machines
        let preference = cache.browserTabs.preference
        chromiumWarmup.start(defaultIsChromium: { preference.defaultEngine == .chromium }, pagesPending: { [weak cache] in cache?.pendingBrowsers.isEmpty == false })
        TabStripSignals.shared.onNewTabButtonHover = { [weak self] in self?.chromiumWarmup.tabSignal(.newTabButton) }
        chromiumLikelyObservations.append(Task { [weak self] in
            // A Chromium tab in any window, restored or created elsewhere, or
            // any browser tab while new tabs default to Chromium.
            for await reason in ObservationStream({ Self.likelyFromTabs(machines, preference.defaultEngine) }) {
                guard let reason else { continue }
                self?.chromiumWarmup.chromiumLikely(reason)
                return
            }
        })
        chromiumLikelyObservations.append(ChromiumPaletteSignal.observe(palette.model, preference: preference, warmup: chromiumWarmup))
    }
}

extension AppServices {
    /// Why the open tabs make a Chromium tab likely, nil when they do not.
    static func likelyFromTabs(_ machines: MachineRegistry, _ defaultEngine: BrowserDefaultEngine) -> ChromiumWarmup.Reason? {
        if machines.hasChromiumTab { return .restoredTab }
        if defaultEngine == .chromium, machines.hasBrowserTab { return .browserTab }
        return nil
    }
}

extension MachineRegistry {
    /// True when any workspace of any machine holds an app-rendered browser
    /// tab (either engine; daemon CDP mirrors do not count).
    var hasBrowserTab: Bool {
        allWorkspaces.contains { workspace, _ in
            workspace.screens.contains { screen in
                screen.panes.contains { pane in pane.tabs.contains { $0.kind == .browser && $0.isFrontendOwned } }
            }
        }
    }

    /// True when any workspace of any machine holds a Chromium tab.
    var hasChromiumTab: Bool {
        allWorkspaces.contains { workspace, _ in
            workspace.screens.contains { screen in
                screen.panes.contains { pane in
                    pane.tabs.contains { $0.browserEngine == BrowserEngineTag.cef.rawValue }
                }
            }
        }
    }
}
