import CmuxNextBrowser
import CmuxNextChromiumWarmup
import CmuxNextCompat
import CmuxNextFeatures
import CmuxNextSettings
import Observation

// When Chromium is likely (ChromiumWarmup): Chromium tabs and the palette's Chromium
// entries (while Chromium is the default engine it starts after launch). The "+" engine menu reports from
// PaneController.contextMenu(for: .newTabButton), the default-engine action
// from SettingsHandlers.
extension AppServices {
    /// Starts the launch preload and the likelihood observers.
    func startChromiumWarmup() {
        let machines = machines
        let preference = cache.browserTabs.preference
        // cmux pages follow `browser.defaultEngine` (ChromiumPageHost): with the feature, their profile
        // keeps a spare window too, so a page's key joins a live window (p13-webui-016).
        let pagesSpare = features.isEnabled(.pagesSpareWindow)
        // Before the first spare: its placeholder has no renderer where the fork can (p13-webui-019).
        cache.cef.setRendererlessSpareWindows(features.isEnabled(.rendererlessSpareWindow))
        chromiumWarmup.start(defaultIsChromium: { preference.defaultEngine == .chromium },
                             pagesPending: { [weak cache] in cache?.pendingBrowsers.isEmpty == false },
                             pagesSpare: { pagesSpare && preference.defaultEngine == .chromium })
        cache.onPagesSettled = { [weak chromiumWarmup] in chromiumWarmup?.pagesSettled() }
        if pagesSpare {
            // Pages follow the default engine: switched away from Chromium, the untaken pages spare
            // closes; switched back, the next idle moment builds it again. The current value is
            // the one `start` already reads; only changes act.
            let (_, engineChanges) = ObservationStream.current({ preference.defaultEngine == .chromium })
            chromiumLikelyObservations.append(Task { [weak self] in
                for await _ in engineChanges { self?.chromiumWarmup.pagesSpareChanged() }
            })
        }
        chromiumLikelyObservations.append(Task { [weak self] in
            // A Chromium tab in any window, restored or created elsewhere. While Chromium is the
            // default engine the launch warm start covers every tab (ChromiumWarmup.start), so the
            // walk of every tab, which tracks every tab and re-runs on any tab change, is skipped:
            // only the default engine is read (pl-o-all, O(all) observers).
            for await reason in ObservationStream({ preference.defaultEngine == .chromium ? nil : Self.likelyFromTabs(machines) }) {
                guard let reason else { continue }
                self?.chromiumWarmup.chromiumLikely(reason)
                return
            }
        })
        palettes.whenBuilt { [weak self] palette in  // the palette is built after launch (p08-startup-023)
            guard let self else { return }
            chromiumLikelyObservations.append(ChromiumPaletteSignal.observe(palette.model, warmup: chromiumWarmup))
        }
    }
}

extension AppServices {
    /// Why the open tabs make a Chromium tab likely, nil when they do not.
    static func likelyFromTabs(_ machines: MachineRegistry) -> ChromiumWarmup.Reason? {
        machines.hasChromiumTab ? .restoredTab : nil
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
