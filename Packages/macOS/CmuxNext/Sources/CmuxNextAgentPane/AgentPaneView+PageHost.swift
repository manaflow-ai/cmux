import AppKit
import CmuxNextPages

/// The agent pane on the shared page host (react-pages.md, agent pane move P2): the bundled page at
/// `cmux-page://cmux.agent/` in a ``PageWebView``, its calls answered by ``AgentPageProvider`` and
/// the host's pushes sent as ``AgentPageEvent``s. The `agent.pageHost` tunable turns it on.
extension AgentPaneView {
    /// The page view for the bundled page in `root`, nil when the page host refuses that root.
    static func makePage(root: URL, provider: AgentPageProvider, renderRate: AgentPaneRenderRate) -> PageWebView? {
        // The agent page's files live in this module's bundle, not the page host's.
        PageID.registerBundledRoot(root, for: PageDescriptor.agent.id)
        return PageWebView(descriptor: .agent, root: root,
                           routes: [PageRoute(prefix: AgentPageOps.namespace, provider: provider)],
                           options: PageEngineOptions(fullFrameRate: renderRate != .capped))
    }

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
            return self?.currentPageEvents() ?? []
        }
        addSubview(page)
    }

    /// What the old host pushed again after each load and handshake: the theme, shortcuts, preview
    /// features, the edited-files card's settings, and a non-empty customization.
    func currentPageEvents() -> [AgentPageEvent] {
        var events: [AgentPageEvent] = []
        if let theme = AgentPageEvent.theme(themeTokens, surface: surfaceKind) { events.append(theme) }
        events.append(.shortcuts(shortcuts))
        events.append(.preview(previewFeatures))
        events.append(.editedFiles(editedFiles))
        if !customization.isEmpty { events += AgentPageEvent.customization(customization) }
        return events
    }
}
