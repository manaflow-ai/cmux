import CmuxNextActions
import CmuxNextControl
import CmuxNextCompat
import CmuxNextMacScreen
import CmuxNextSettings
import Foundation

/// The app's side of Mac Screen tabs (`MacScreenPages` owns the rest).
extension AppServices {
    static func makeMacScreenPages(_ services: AppServices) -> MacScreenPages {
        let pages = MacScreenPages(store: .forApplication(bundleIdentifier: services.environment.launch.bundleID))
        pages.useShortcuts(of: services.registry)
        return pages
    }

    /// DEV builds: Settings > Development > Relay Only drives every Mac Screen session.
    func followMacScreenSettings(_ settings: SettingsController) {
        #if DEBUG
        Task { [weak self] in
            for await relayOnly in ObservationStream({ settings.snapshot.macScreenDebug.relayOnly }) {
                self?.macScreenPages.relayOnly = relayOnly
            }
        }
        #endif
    }

    /// New Mac Screen Tab: the home page in the pane the action ran on, else the active window's focused pane.
    func openMacScreen(in target: PaneController?) {
        guard let pane = target ?? windows.active?.focusedPane else { return registry.refuse(RefusalStrings.noWindowOpen) }
        pane.newBrowserTab(url: MacScreenRecord.homeURL)
    }

    func registerMacScreenDebug(on router: ControlRouter?) {
        macScreenPages.registerDebug(on: router) { [weak self] url, key in
            let named = key.flatMap { key in self?.windows.controllers.lazy.compactMap { $0.content?.panes.values.first { $0.paneKey == key } }.first }
            guard let pane = named ?? self?.windows.active?.focusedPane ?? self?.windows.controllers.first?.focusedPane else { return "no pane" }
            pane.newBrowserTab(url: url)
            return nil
        }
    }
}
