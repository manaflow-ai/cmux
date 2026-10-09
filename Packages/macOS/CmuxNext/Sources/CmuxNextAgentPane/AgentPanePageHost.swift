import AppKit
import CmuxNextPages

/// The agent page host's pieces that need no view state of their own: making the page and the
/// events a new page subscriber gets. Kept off ``AgentPaneView``, whose type is at its size limit.
enum AgentPanePageHost {
    /// The page view for the bundled page in `root`, nil when the page host refuses that root.
    static func makePage(root: URL, provider: AgentPageProvider, renderRate: AgentPaneRenderRate) -> PageWebView? {
        // The agent page's files live in this module's bundle, not the page host's.
        PageID.registerBundledRoot(root, for: PageDescriptor.agent.id)
        return PageWebView(descriptor: .agent, root: root,
                           routes: [PageRoute(prefix: AgentPageOps.namespace, provider: provider)],
                           options: PageEngineOptions(fullFrameRate: renderRate != .capped))
    }

    /// What the old host pushed again after each load and handshake: the theme, shortcuts, preview
    /// features, the edited-files card's and the composer's settings, and a non-empty customization.
    @MainActor static func currentEvents(_ view: AgentPaneView) -> [AgentPageEvent] {
        var events: [AgentPageEvent] = []
        if let theme = AgentPageEvent.theme(view.themeTokens, surface: view.surfaceKind) { events.append(theme) }
        events.append(.shortcuts(view.shortcuts))
        events.append(.preview(view.previewFeatures))
        events.append(.deviceChats(view.deviceChats))
        events.append(.editedFiles(view.editedFiles))
        events.append(.composer(view.model.composer))
        if !view.customization.isEmpty { events += AgentPageEvent.customization(view.customization) }
        return events
    }
}
