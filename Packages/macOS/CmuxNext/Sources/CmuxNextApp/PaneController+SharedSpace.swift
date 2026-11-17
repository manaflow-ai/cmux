import AppKit
import CmuxNextDaemon
import CmuxNextDesign

/// A pane of a workspace that two windows show (two windows on one space,
/// plans/cmux-next/spaces-overhaul-DESIGN.md rule 6).
///
/// - A terminal draws in both windows: the window that owns the workspace shows the cache's
///   surface, a guest window a view of its own (`TabContentCache.guestTerminal`).
/// - Every other kind has one view (a page has one renderer): the window that showed it first
///   keeps it, the other says so and offers Show Here. Nothing takes a view by itself, so two
///   windows never pass one view back and forth.
extension PaneController {
    /// This pane's window shows its workspace as a guest: another window owns it.
    var isGuestView: Bool { workspace?.isGuestView == true }

    // MARK: Terminals

    /// This guest pane's own view of terminal `tab`; nil while the tab is a stand-in (it shows at its confirm).
    func guestTerminalContent(_ tab: TabModel) -> TabContent? {
        guard !ProvisionalTab.isProvisional(surface: tab.surface), stripModel.selectedID?.rawValue == tab.id else { return nil } // only the shown tab has a view
        if let guest = guestTerminal, guest.key == tab.id, guest.entry.validity == daemon.terminalViewValidity(of: tab) {
            return .terminal(guest.entry)
        }
        if guestTerminal != nil { view.detachContent(parks: false) } // its view leaves before its surface closes
        dropGuestTerminal()
        let entry = services.cache.guestTerminal(for: tab, daemon: daemon, visible: presence == .visible && !isSuspended)
        services.themes.catchUp(entry, fresh: true)
        TabRestart.offer(on: entry, tab: tab, daemon: daemon, registry: services.registry)
        guestTerminal = (tab.id, entry)
        return .terminal(entry)
    }

    /// Closes the guest view unless it is `key`'s (the pane shows another tab, or goes).
    func dropGuestTerminal(keeping key: String? = nil) {
        guard let guest = guestTerminal, guest.key != key else { return }
        guestTerminal = nil
        services.cache.closeGuestTerminal(guest.entry)
    }

    /// The guest view draws, and counts for the terminal's size, only while this pane is on screen.
    func syncGuestTerminal() {
        guard let entry = guestTerminal?.entry else { return }
        let visible = presence == .visible && !isSuspended
        guard entry.session.isRenderingSuspended == visible else { return }
        entry.session.isRenderingSuspended = !visible
        entry.io.setVisible(visible)
    }

    // MARK: One-view tabs

    /// The same pane of another window that draws tab `key` now, when the tab has one view.
    func paneShowingElsewhere(_ key: String) -> PaneController? {
        // A terminal draws in each window; every other tab (a page tab of the pane too, which no record lists) has one view.
        guard let id = workspace?.workspace.id, let own = state?.id, services.windows.controllers.count > 1,
              pane.tabs.first(where: { $0.id == key })?.kind != .pty else { return nil }
        for controller in services.windows.controllers where controller.state.id != own {
            guard let content = controller.content, content.workspace.id == id, let other = content.paneController(key: paneKey),
                  other.currentTabKey == key, other.elsewhereNotice?.key != key, !other.isSuspended, other.view.hostsContent else { continue }
            return other
        }
        return nil
    }

    /// The notice for tab `key`, whose view another window shows.
    func elsewhereContent(_ key: String) -> TabContent {
        if let notice = elsewhereNotice, notice.key == key { return .notice(notice.view) }
        let view = TabShownElsewhereView(message: WindowStrings.tabShownElsewhere, action: WindowStrings.tabShowHere) { [weak self] in self?.showHere(key) }
        elsewhereNotice = (key, view)
        return .notice(view)
    }

    /// This pane stopped drawing tab `key` (it shows another tab, its workspace left the screen, or it goes): the same
    /// pane of another window that shows the notice for `key` shows the tab itself now.
    func stoppedDrawing(_ key: String?) {
        guard let key, services.windows.controllers.count > 1, elsewhereNotice?.key != key, let id = workspace?.workspace.id else { return }
        for controller in services.windows.controllers where controller.state.id != state?.id {
            guard let content = controller.content, content.workspace.id == id,
                  let other = content.paneController(key: paneKey), other !== self, other.elsewhereNotice?.key == key else { continue }
            other.showSelected()
        }
    }

    /// Show Here: this pane takes tab `key`'s view, and the pane that drew it says where it went.
    func showHere(_ key: String) {
        guard stripModel.selectedID?.rawValue == key else { return }
        let losers = services.windows.controllers.compactMap { $0.content?.paneController(key: paneKey) }
            .filter { $0 !== self && $0.workspace?.workspace.id == workspace?.workspace.id && $0.stripModel.selectedID?.rawValue == key }
        takesHere = key
        showSelected()
        takesHere = nil
        for loser in losers { loser.showSelected() }
    }
}
