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

    private func show(_ page: AgentPaneNewTab) {
        guard model.newTab == page, let data = try? JSONEncoder().encode(page),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateScript("window.dispatchEvent(new CustomEvent('acpmux-newtab-adopt', {detail: \(json)}))")
        applyTheme()
    }
}
