import AppKit
import CmuxNextBridge

extension InternalPageTabStore {
    /// The catalog show action of every page (`openSettings`,
    /// `openDebugSettings`, `appStore.show`): selects `page`'s tab in
    /// `window`, else opens one after the focused pane's selected tab: a
    /// store tab where the pane's daemon holds page tabs, else an app-only one.
    /// A user run selects and focuses it, and a window on a top page leaves
    /// the page so the tab shows (SIDEBAR-SELECTION-ONE-MODEL); automation
    /// (`ActionInvocation.allowsViewChange` false) opens it without changing
    /// the selection, focus or page (under a page, in the parked workspace).
    /// Returns the tab's view, or nil when `window` has no pane to hold it.
    @discardableResult
    func show(_ page: InternalPageID, in window: WindowController?, focus: Bool) -> InternalPageView? {
        guard let window else { return nil }
        if focus { window.leaveTopPage() }
        guard let content = window.workspaceContent else { return nil }
        let panes = content.panes.values
        for pane in panes {
            guard let tab = pane.pane.tabs.first(where: { $0.page == page.rawValue }) else { continue }
            if focus { reveal(tab.id, in: pane) }
            return view(forStoreTab: tab, in: pane.daemon.store, window: window)
        }
        if let found = tab(of: page, inPanes: panes.map(\.paneKey)),
           let pane = panes.first(where: { $0.paneKey == found.pane }) {
            if focus { reveal(found.key, in: pane) }
            return view(for: found.key)
        }
        guard let pane = content.focusedPane ?? panes.first else { return nil }
        if let view = openStoreTab(page, in: pane, window: window, focus: focus) { return view }
        let key = open(page, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue, window: window)
        pane.apply(pane.snapshot())
        if focus { reveal(key, in: pane) }
        return view(for: key)
    }

    func reveal(_ key: String, in pane: PaneController) {
        pane.select(StripTabID(key))
        pane.focusContent()
    }

    /// The main window that shows a tab of `page` (debug and tests).
    func window(showing page: InternalPageID, windows: [WindowController]) -> WindowController? {
        windows.first { controller in
            guard let panes = controller.content?.panes.values else { return false }
            return tab(of: page, inPanes: panes.map(\.paneKey)) != nil
                || panes.contains { $0.pane.tabs.contains { $0.page == page.rawValue } }
        }
    }
}

extension AppServices {
    /// The pane controller whose strip lists the page tab `key` (its
    /// provider key, or a store page tab's id).
    func paneController(showingTab key: String) -> PaneController? {
        for controller in windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pages.stripID(showing: key, in: pane) != nil || pane.tab(StripTabID(key))?.page != nil {
                return pane
            }
        }
        return nil
    }
}
