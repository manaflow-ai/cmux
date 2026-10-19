import AppKit
import CmuxNextPages

/// The agent pane on the shared page host (react-pages.md, agent pane move P2): the bundled page at
/// `cmux-page://cmux.agent/` in a ``PageWebView``, its calls answered by ``AgentPageProvider`` and
/// the host's pushes sent as ``AgentPageEvent``s. The `agent.pageHost` tunable turns it on.
extension AgentPaneView {
    /// Wires `page` to this view: navigation, crashes, and the state a new page subscriber gets.
    func attachPage(_ page: PageWebView) {
        page.autoresizingMask = [.width, .height]
        page.onOpenExternal = { [weak self, weak page] url in
            guard let self else { return }
            let other = LinkRouter.isOtherTarget(page?.externalLinkModifiers ?? [])
            _ = AgentPaneNavigation.openOutside(url, gestures: self.model.transport.gestures) { self.openURL($0, other) }
        }
        page.onNavigate = { [weak self] navigation in
            guard let self else { return .cancel }
            switch AgentPaneNavigation.decision(for: navigation, source: self.source) {
            case .allow: return .allow
            case .openOutside: return .openExternal
            case .cancel: return .cancel
            }
        }
        page.onCrash = { [weak self] _, reloading in self?.pageCrashed(reloading: reloading) }
        pageEvents?.replay = { [weak self] in
            // A new subscriber is a page that loaded again: its registry renderers are gone.
            guard let self else { return [] }
            self.runPageHostRegistry()
            let events = AgentPanePageHost.currentEvents(self)
            // The theme it gets here is the one it has now, whatever was pushed before.
            self.deliveredThemeEvent = events.first { $0.kind == "theme" }
            return events
        }
        addSubview(page)
    }
}
