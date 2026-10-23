import Foundation

extension AgentPaneView {
    /// Cmd-T adopted this prewarmed page (plans/cmux-next/new-tab.md section
    /// 2.2): the model takes the tab's context, the page gets it as an
    /// `acpmux-newtab-adopt` event (WebKit runs it before any key typed after
    /// Cmd-T) and remounts the screen, and the theme follows the scope the
    /// view moved into. A page still loading reads the context from its
    /// handshake instead.
    public func adoptNewTab(_ page: AgentPaneNewTab) {
        model.adoptNewTab(page)
        show(page)
    }

    /// A chat without a session that is a new tab page after all
    /// (``AgentPaneModel/becomeNewTab(_:)``): the page shows it at once.
    public func becomeNewTab(_ page: AgentPaneNewTab) {
        model.becomeNewTab(page)
        show(page)
    }

    /// The open tabs and workspaces changed while this page shows (Leo 2026-10-11: rows for New
    /// Tab pages and workspaces gone since stayed listed). The page's bar takes the new places in
    /// place, as an `acpmux-newtab-places` event, with no remount: what is typed stays.
    public func refreshNewTabPlaces(tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace]) {
        guard model.sessionId == nil, var page = model.newTab,
              page.omnibar.tabs != tabs || page.omnibar.workspaces != workspaces else { return }
        page.omnibar.tabs = tabs
        page.omnibar.workspaces = workspaces
        model.adoptNewTab(page)
        guard let data = try? JSONEncoder().encode(page.omnibar), let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-places', {detail: \(json)}))")
    }

    /// Sends `page` into the page as its new context. A page that listed its own chats drops
    /// carried ones (webviews newtab/warmSnapshot.ts `listedOnce`), so they are left out for it:
    /// up to ``AgentPaneNewTab/maximumWarmBytes`` of JSON text, escaped again in the context, on
    /// the key's turn of every Cmd-T and Cmd-N. The model keeps them for the page's handshake.
    private func show(_ page: AgentPaneNewTab) {
        guard model.newTab == page else { return }
        var sent = page
        if model.listedOwnChats { sent.warm = nil }
        guard let data = try? JSONEncoder().encode(sent), let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-adopt', {detail: \(json)}))")
        applyTheme()
    }
}
