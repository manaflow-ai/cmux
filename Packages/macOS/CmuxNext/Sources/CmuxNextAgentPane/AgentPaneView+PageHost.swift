import AppKit
import CmuxNextPages

/// The agent pane on the shared page host (react-pages.md, agent pane move P2): the bundled page at
/// `cmux-page://cmux.agent/` in a ``PageWebView``, its calls answered by ``AgentPageProvider`` and
/// the host's pushes sent as ``AgentPageEvent``s. The `agent.pageHost` tunable turns it on.
extension AgentPaneView {
    /// Wires `page` to this view: navigation, crashes, and the state a new page subscriber gets.
    func attachPage(_ page: PageWebView) {
        page.autoresizingMask = [.width, .height]
        page.onOpenExternal = { [weak self] url in
            guard let self else { return }
            _ = AgentPaneNavigation.openOutside(url, gestures: self.model.transport.gestures, open: self.openURL)
        }
        page.onNavigate = { [weak self] navigation in
            guard let self else { return .cancel }
            switch AgentPaneNavigation.decision(for: navigation.url, source: self.source,
                                                userClicked: navigation.userClicked, mainFrame: navigation.mainFrame) {
            case .allow: return .allow
            case .openOutside: return .openExternal
            case .cancel: return .cancel
            }
        }
        page.onCrash = { [weak self] _, reloading in self?.pageCrashed(reloading: reloading) }
        pageEvents?.replay = { [weak self] in
            // A new subscriber is a page that loaded again: its registry renderers are gone.
            self?.runPageHostRegistry()
            return self.map(AgentPanePageHost.currentEvents) ?? []
        }
        addSubview(page)
    }
}
