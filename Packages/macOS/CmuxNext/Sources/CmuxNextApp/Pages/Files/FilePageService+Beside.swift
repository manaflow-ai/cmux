import CmuxNextBridge
import CmuxNextDaemon
import Foundation

/// A chat's click on a file opens its page beside the chat (ChatBeside): in the pane right of the
/// chat, where a tab that already shows the file is selected and no keyboard focus moves.
extension FilePageService {
    /// Selects the tab of `pane` that shows `file`, moving no keyboard focus. False when no tab of
    /// `pane` shows it.
    func selectShown(_ file: URL, in pane: PaneController) -> Bool {
        let real = file.standardizedFileURL.resolvingSymlinksInPath()
        let pages = pane.services.pages
        let keys = pages.tabIDs(in: pane.paneKey) + pane.pane.tabs.compactMap { pages.storeKey(of: $0.id) }
        if let shown = keys.first(where: { self.file($0) == real }) {
            pane.select(pages.stripID(showing: shown, in: pane) ?? StripTabID(shown))
        } else if let unshown = pane.pane.tabs.first(where: { $0.page == kind.page.rawValue && $0.pageRoute == real.path }) {
            pane.select(StripTabID(unshown.id))
        } else {
            return false
        }
        return true
    }

    /// Whether a new tab of this page in `pane` is a store tab, the only kind a placement beside a
    /// chat can move. A reconnecting daemon makes none, so the click takes the old path.
    func opensStoreTabs(in pane: PaneController) -> Bool {
        guard case .connected = pane.daemon.store.connectionState,
              pane.daemon.supports(DaemonCapabilities.shared.pageTabs) else { return false }
        return pane.services.windowController(showing: pane) != nil && pane.daemon.isLocal && pane.services.pages.keepsRoutes(pane.daemon)
    }
}
