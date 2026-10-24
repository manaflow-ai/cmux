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

    /// The open tabs and workspaces changed (Leo 2026-10-11: rows for New Tab pages and workspaces
    /// gone since stayed listed). The page's bar takes the new places in place, with no remount:
    /// what is typed stays. A push of the host's state: on the page host it is a `newTabPlaces`
    /// event, which a frozen hidden page gets once, the newest, at its thaw (PATTERNS.md P10; a
    /// host script here thawed it on every terminal title change). The old host gets an
    /// `acpmux-newtab-places` script.
    public func refreshNewTabPlaces(tabs: [AgentPaneOmnibar.Tab], workspaces: [AgentPaneOmnibar.Workspace]) {
        guard model.sessionId == nil, var page = model.newTab,
              page.omnibar.tabs != tabs || page.omnibar.workspaces != workspaces else { return }
        page.omnibar.tabs = tabs
        page.omnibar.workspaces = workspaces
        model.adoptNewTab(page)
        let omnibar = page.omnibar
        deliver(AgentPageEvent.newTabPlaces(omnibar).map { [$0] } ?? [], scripts: { () -> [String] in
            guard let data = try? JSONEncoder().encode(omnibar), let json = String(data: data, encoding: .utf8) else { return [] }
            return ["window.dispatchEvent(new CustomEvent('acpmux-newtab-places', {detail: \(json)}))"]
        }())
    }

    /// The weather widget's reading arrived or changed (``AgentPaneNewTab/weather``): the page takes
    /// it in place, with no remount. nil (the widget turned off) takes the reading away. A push of
    /// the host's state: a `newTabWeather` event on the page host (a frozen page gets the newest at
    /// its thaw), an `acpmux-newtab-weather` script on the old host.
    public func refreshNewTabWeather(_ weather: AgentPaneNewTabWeather?) {
        guard model.sessionId == nil, var page = model.newTab, page.weather != weather else { return }
        page.weather = weather
        model.adoptNewTab(page)
        deliver([.newTabWeather(weather)], scripts: { () -> [String] in
            let json = weather.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            return ["window.dispatchEvent(new CustomEvent('acpmux-newtab-weather', {detail: \(json)}))"]
        }())
    }

    private func show(_ page: AgentPaneNewTab) {
        guard model.newTab == page, let data = try? JSONEncoder().encode(page),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-adopt', {detail: \(json)}))")
        applyTheme()
    }
}
