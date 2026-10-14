import CmuxNextActions
import CmuxNextControl
import CmuxNextMacScreen
import Foundation

/// The app's side of Mac Screen tabs (`MacScreenPages` owns the rest).
extension AppServices {
    static func makeMacScreenPages(_ services: AppServices) -> MacScreenPages {
        let pages = MacScreenPages(store: .forApplication(bundleIdentifier: services.environment.launch.bundleID))
        pages.useShortcuts(of: services.registry)
        return pages
    }

    /// Selects `target`'s Mac Screen home tab, else opens one there.
    /// `target` is the pane the action ran on, else the active window's focused pane.
    func openMacScreen(in target: PaneController?) {
        guard let pane = target ?? windows.active?.focusedPane else { return registry.refuse(RefusalStrings.noWindowOpen) }
        let home = pane.pane.tabs.first { $0.url.flatMap(URL.init(string:)).flatMap(MacScreenRecord.init(url:)).map { $0.macID == nil } == true }
        if let home { pane.select(StripTabID(home.id)) } else { pane.newBrowserTab(url: MacScreenRecord.homeURL) }
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
