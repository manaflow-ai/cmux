import Foundation

extension AgentPaneView {
    /// Cmd-T adopted this prewarmed page (plans/cmux-next/new-tab.md section
    /// 2.2): the model takes the tab's context, the page gets it as an
    /// `acpmux-newtab-adopt` event (WebKit runs it before any key typed after
    /// Cmd-T) and remounts the screen unless it already draws that context
    /// (``prepareNewTab(_:)``), and the theme follows the scope the view moved into. A page still loading reads the context from its
    /// handshake instead.
    public func adoptNewTab(_ page: AgentPaneNewTab) {
        model.adoptNewTab(page)
        model.newTabPrepared = false
        // With what a new chat of the window left, unless the host already gave it one (cmux#32276).
        show(page, sending: model.newTabForPage)
    }

    /// A parked spare takes `page`, the context a Cmd-T would give it, before the key (NewTabSparePool), unless it
    /// already draws that screen: its adoption then changes no screen. Only an untouched New Tab page that finished
    /// its handshake and first paint (an adopt event before React listens is lost); its handshake folder stays the
    /// load's (``AgentPaneModel/newTabPrepared``), and its old remembered frame goes. Returns whether it took it.
    @discardableResult
    public func prepareNewTab(_ page: AgentPaneNewTab) -> Bool {
        guard model.hasHandshake, model.hasPainted, model.newTab != nil, !model.userTouched,
              model.newTab?.drawsSameScreen(as: page) != true else { return false }
        model.adoptNewTab(page)
        model.newTabPrepared = true
        redraw.forgetRememberedFrame()
        show(page)
        return true
    }

    /// A chat without a session that is a new tab page after all
    /// (``AgentPaneModel/becomeNewTab(_:)``): the page shows it at once.
    public func becomeNewTab(_ page: AgentPaneNewTab) {
        model.becomeNewTab(page)
        // With what a new chat of the window left, as a handshake gives it (cmux#32276).
        show(page, sending: model.newTabForPage)
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
        // Only the two lists that changed: the page takes `tabs` and `workspaces` from this event and keeps the
        // rest of its bar (webviews newtab/adoption.ts `useNewTabPlaces`). The whole bar (every palette action,
        // recent pages, commands) was 32 of the 37 ms after Ctrl-`'s handler: each tab change runs this before
        // the key's commit (NewTabPlacesFeed, SHORTCUT LATENCY 2026-11-02).
        guard let data = try? JSONEncoder().encode(PlacesEvent(tabs: tabs, workspaces: workspaces)),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-places', {detail: \(json)}))")
    }

    /// The `acpmux-newtab-places` event's detail: the bar's open tabs and workspaces only.
    private nonisolated struct PlacesEvent: Encodable {
        let tabs: [AgentPaneOmnibar.Tab]
        let workspaces: [AgentPaneOmnibar.Workspace]
    }

    /// The Commands palette's actions for the bar arrived (``AgentPaneNewTabActions`` lists them after the page
    /// shows, so Cmd-T does not wait for them): the page takes them in place, in the same
    /// `acpmux-newtab-places` event, with no remount, so what is typed stays. The actions' JSON comes encoded
    /// (off the main thread, once for every page); only the page's own tabs and workspaces are encoded here.
    public func refreshNewTabActions(_ listed: AgentPaneNewTabActions.Listed) {
        guard model.sessionId == nil, var page = model.newTab, page.omnibar.actions != listed.actions else { return }
        page.omnibar.actions = listed.actions
        model.adoptNewTab(page)
        let encoder = JSONEncoder()
        guard let tabs = try? encoder.encode(page.omnibar.tabs), let workspaces = try? encoder.encode(page.omnibar.workspaces),
              let tabsJSON = String(data: tabs, encoding: .utf8), let workspacesJSON = String(data: workspaces, encoding: .utf8) else { return }
        // The page's places handler sets the bar's tabs and workspaces from each event: they go with the actions.
        let detail = "{\"tabs\":\(tabsJSON),\"workspaces\":\(workspacesJSON),\"actions\":\(listed.json)}"
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-places', {detail: \(detail)}))")
    }

    /// The weather widget's reading arrived or changed while this page shows (``AgentPaneNewTab/weather``):
    /// the page takes it in place, as an `acpmux-newtab-weather` event, with no remount. nil (the
    /// widget turned off) takes the reading away.
    public func refreshNewTabWeather(_ weather: AgentPaneNewTabWeather?) {
        guard model.sessionId == nil, var page = model.newTab, page.weather != weather else { return }
        page.weather = weather
        model.adoptNewTab(page)
        let json = weather.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-weather', {detail: \(json)}))")
    }

    private func show(_ page: AgentPaneNewTab, sending sent: AgentPaneNewTab? = nil) {
        guard model.newTab == page, let data = try? JSONEncoder().encode(sent ?? page),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-adopt', {detail: \(json)}))")
        applyTheme()
    }
}
