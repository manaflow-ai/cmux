import AppKit
import CmuxNextBridge

extension InternalPageTabStore {
    /// The catalog show action of every page (`openSettings`,
    /// `openDebugSettings`, `appStore.show`): selects `page`'s tab in
    /// `window`, else opens one after the focused pane's selected tab.
    /// A user run selects and focuses it; automation (`viewChangeAllowed`
    /// false) opens it without changing the selection or focus. Returns the
    /// tab's view, or nil when `window` has no pane to hold it.
    @discardableResult
    func show(_ page: InternalPageID, in window: WindowController?, focus: Bool) -> InternalPageView? {
        guard let window, let content = window.content else { return nil }
        let panes = content.panes.values
        if let found = tab(of: page, inPanes: panes.map(\.paneKey)),
           let pane = panes.first(where: { $0.paneKey == found.pane }) {
            if focus { reveal(found.key, in: pane) }
            return view(for: found.key)
        }
        guard let pane = window.focusedPane ?? panes.first else { return nil }
        let key = open(page, in: pane.paneKey, of: pane.daemon.store, after: pane.stripModel.selectedID?.rawValue, window: window)
        pane.apply(pane.snapshot())
        if focus { reveal(key, in: pane) }
        return view(for: key)
    }

    private func reveal(_ key: String, in pane: PaneController) {
        pane.select(StripTabID(key))
        pane.focusContent()
    }

    /// The main window that shows a tab of `page` (debug and tests).
    func window(showing page: InternalPageID, windows: [WindowController]) -> WindowController? {
        windows.first { controller in
            guard let panes = controller.content?.panes.values else { return false }
            return tab(of: page, inPanes: panes.map(\.paneKey)) != nil
        }
    }
}

extension AppServices {
    /// The pane controller whose strip lists the page tab `key`.
    func paneController(showingTab key: String) -> PaneController? {
        for controller in windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pages.tabIDs(in: pane.paneKey).contains(key) {
                return pane
            }
        }
        return nil
    }
}
