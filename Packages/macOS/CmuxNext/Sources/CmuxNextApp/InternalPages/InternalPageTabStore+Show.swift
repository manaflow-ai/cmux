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
    /// A user run where a tab would not be seen (Home stands for the hidden
    /// home workspace, or the workspace has no pane) shows the page as the
    /// window's top page instead, and a page already shown on top shows
    /// again (cx-cmge7: What's New on Home opened a tab in the hidden home
    /// workspace and nothing showed).
    /// Returns the tab's (or top page's) view, or nil when nothing can hold it.
    @discardableResult
    func show(_ page: InternalPageID, in window: WindowController?, focus: Bool) -> InternalPageView? {
        guard let window else { return nil }
        if Self.isPreviewPage(page),
           window.services.settings?.snapshot.previewFeatures != true { return nil }
        if focus, window.shownTopPage == .page(page) || !window.holdsVisiblePageTab {
            return showTopPage(page, in: window)
        }
        if focus { window.leaveTopPage() }
        guard let content = window.workspaceContent else { return nil }
        // The model's panes: a workspace parked under a top page lays out nothing, so its view's
        // panes may lack one the daemon added or still hold one it closed.
        let panes = content.modelPanes
        let daemon = content.daemon
        for pane in panes {
            guard let tab = pane.tabs.first(where: { $0.page == page.rawValue }) else { continue }
            if focus, let controller = content.controller(for: pane) { reveal(tab.id, in: controller) }
            return view(forStoreTab: tab, in: daemon.store, local: daemon.isLocal, window: window)
        }
        if let found = tab(of: page, inPanes: panes.map(\.id)) {
            if focus, let controller = panes.first(where: { $0.id == found.pane }).flatMap(content.controller(for:)) {
                reveal(found.key, in: controller)
            }
            return view(for: found.key)
        }
        return openNew(page, in: window, focus: focus)
    }

    /// One more tab of `page` after `window`'s focused pane's selected tab,
    /// even when the window lists one already (`home.tab`): a store tab
    /// where the pane's daemon holds page tabs, else an app-only one. Focus
    /// as in ``show(_:in:focus:)``. Nil when `window` has no pane.
    @discardableResult
    func openNew(_ page: InternalPageID, in window: WindowController?, focus: Bool) -> InternalPageView? {
        guard let window else { return nil }
        if Self.isPreviewPage(page),
           window.services.settings?.snapshot.previewFeatures != true { return nil }
        if focus { window.leaveTopPage() }
        // Never in a dock (the docked Home, a chat dock): beside it. Chosen from the model: a
        // workspace parked under a top page shows nothing of a pane the daemon changed meanwhile.
        guard let content = window.workspaceContent, let model = content.pageTabModelPane else { return nil }
        let pane = content.controller(for: model)
        if let view = openStoreTab(page, in: model, of: content.daemon, services: window.services, controller: pane,
                                   window: window, focus: focus) { return view }
        let key = open(page, in: model.id, of: content.daemon.store, after: pane?.stripModel.selectedID?.rawValue, window: window)
        if let pane {
            pane.apply(pane.snapshot())
            if focus { reveal(key, in: pane) }
        }
        return view(for: key)
    }

    /// `page` as `window`'s top page (one view per window, shown again on a
    /// repeat); nil when the run may not change the view.
    private func showTopPage(_ page: InternalPageID, in window: WindowController) -> InternalPageView? {
        let route = TopPageRoute.page(page)
        guard TopPages.show(route, services: window.services, in: window.state) != nil else { return nil }
        return window.topPages.views[route] as? InternalPageView
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
    /// Whether `page` shows anywhere: a tab, or a window's top page (a
    /// focused show on Home opens it on top). A provider keeps a shared
    /// model while this is true.
    func pageIsOpen(_ page: InternalPageID) -> Bool {
        !pages.keys(of: page).isEmpty || windows.controllers.contains { $0.topPages.key(for: .page(page)) != nil }
    }

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
