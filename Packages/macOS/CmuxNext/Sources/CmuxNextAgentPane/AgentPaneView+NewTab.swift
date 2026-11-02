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

    /// A parked spare takes `page`, the context a Cmd-T would give it, before the key (NewTabSparePool), unless it
    /// already draws that screen; an untouched New Tab page only. Its adoption then changes no screen.
    public func prepareNewTab(_ page: AgentPaneNewTab) {
        guard model.newTab != nil, !model.userTouched, model.newTab?.drawsSameScreen(as: page) != true else { return }
        adoptNewTab(page)
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

    /// The Commands palette's actions for the bar arrived (they are listed on the frame after the page
    /// shows, so Cmd-T does not wait for them): the page takes them in place, in the same
    /// `acpmux-newtab-places` event, with no remount, so what is typed stays.
    public func refreshNewTabActions(_ actions: [AgentPaneOmnibar.Action]) {
        guard model.sessionId == nil, var page = model.newTab, page.omnibar.actions != actions else { return }
        page.omnibar.actions = actions
        model.adoptNewTab(page)
        guard let data = try? JSONEncoder().encode(page.omnibar), let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-places', {detail: \(json)}))")
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

    private func show(_ page: AgentPaneNewTab) {
        guard model.newTab == page, let data = try? JSONEncoder().encode(page),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-adopt', {detail: \(json)}))")
        applyTheme()
    }
}
