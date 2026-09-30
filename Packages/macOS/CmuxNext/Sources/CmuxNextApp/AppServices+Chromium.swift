import CmuxNextBrowser
import Observation

// When Chromium is likely (ChromiumWarmup): restored Chromium tabs and the
// palette's Chromium entries. The "+" engine menu reports from
// PaneController.contextMenu(for: .newTabButton).
extension AppServices {
    static let chromiumPaletteRows: Set<String> = ["action:openBrowser.chromium", "action:browser.openInChromium"]

    /// Starts the launch preload and the likelihood observers.
    func startChromiumWarmup() {
        chromiumWarmup.start()
        let machines = machines
        chromiumLikelyObservations.append(Task { [weak self] in
            // A Chromium tab in any window, restored or created elsewhere.
            for await found in Observations({ machines.hasChromiumTab }) where found {
                self?.chromiumWarmup.chromiumLikely(.restoredTab)
                return
            }
        })
        let model = palette.model
        chromiumLikelyObservations.append(Task { [weak self] in
            for await rows in Observations({ [model.selectedRowID, model.hoveredRowID] }) {
                guard rows.contains(where: { $0.map(Self.chromiumPaletteRows.contains) ?? false }) else { continue }
                self?.chromiumWarmup.chromiumLikely(.palette)
                return
            }
        })
    }
}

extension MachineRegistry {
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
