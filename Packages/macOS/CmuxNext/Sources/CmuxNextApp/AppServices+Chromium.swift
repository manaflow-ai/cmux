import CmuxNextBrowser
import CmuxNextSettings
import Observation

// When Chromium is likely (ChromiumWarmup): Chromium tabs, the palette's
// Chromium entries and, while Chromium is the default engine, any browser tab
// and the palette's default browser entries. The "+" engine menu reports from
// PaneController.contextMenu(for: .newTabButton), the default-engine action
// from SettingsHandlers.
extension AppServices {
    static let chromiumPaletteRows: Set<String> = ["action:openBrowser.chromium", "action:browser.openInChromium"]
    /// Rows that open a tab on the default engine.
    static let defaultBrowserPaletteRows: Set<String> = [
        "action:openBrowser", "action:splitBrowserRight", "action:splitBrowserDown", "action:newBrowserWorkspace",
    ]

    /// Starts the launch preload and the likelihood observers.
    func startChromiumWarmup() {
        chromiumWarmup.start()
        let machines = machines
        let preference = cache.browserTabs.preference
        chromiumLikelyObservations.append(Task { [weak self] in
            // A Chromium tab in any window, restored or created elsewhere, or
            // any browser tab while new tabs default to Chromium.
            for await reason in Observations({ Self.likelyFromTabs(machines, preference.defaultEngine) }) {
                guard let reason else { continue }
                self?.chromiumWarmup.chromiumLikely(reason)
                return
            }
        })
        let model = palette.model
        chromiumLikelyObservations.append(Task { [weak self] in
            for await rows in Observations({ [model.selectedRowID, model.hoveredRowID] }) {
                let likely = Self.chromiumPaletteRows.union(preference.defaultEngine == .chromium ? Self.defaultBrowserPaletteRows : [])
                guard rows.contains(where: { $0.map(likely.contains) ?? false }) else { continue }
                self?.chromiumWarmup.chromiumLikely(.palette)
                return
            }
        })
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
