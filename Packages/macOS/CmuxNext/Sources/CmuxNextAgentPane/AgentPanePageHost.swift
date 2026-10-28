import AppKit
import CmuxNextCompat
import CmuxNextPages
import CmuxNextWakeups

/// The agent page host's pieces that need no view state of their own: making the page and the
/// events a new page subscriber gets. Kept off ``AgentPaneView``, whose type is at its size limit.
enum AgentPanePageHost {
    /// The page view `webUI` opens for the bundled page in `root`, nil when the page host refuses that root.
    /// `chatOpen`: the agent chat open the page shows, nil when none made it. `chromiumChat`: whether the page
    /// may show in Chromium (feature `agentChromium`, as the app resolved it for this page). `origin`: who asks for the page.
    /// `work`: the app's blocking-work lanes, where the page's libraries and media are read.
    static func makePage(root: URL, provider: AgentPageProvider, renderRate: AgentPaneRenderRate,
                         webUI: WebUIHost, chatOpen: ChatOpenStages?, chromiumChat: Bool, origin: PageOpenOrigin,
                         work: any MayBlockRunner) -> PageWebView? {
        // The agent page's files live in this module's bundle, not the page host's.
        PageID.registerBundledRoot(root, for: PageDescriptor.agent.id)
        let page = webUI.open(PageOpenRequest(descriptor: .agent, root: root,
                                              routes: [PageRoute(prefix: AgentPageOps.namespace, provider: provider)],
                                              documentAttributes: AgentPaneTunables.documentAttributes,
                                              options: PageEngineOptions(fullFrameRate: renderRate != .capped,
                                                                         chromiumAgentChat: chromiumChat,
                                                                         sharesWebKitProcess: true),
                                              dynamicResources: AgentPageResources(runner: work), chatOpen: chatOpen, origin: origin))
        // The composer menu's edits run as the page view's own responder actions.
        provider.onEdit = { [weak page] command in page?.performEdit(command.selector) }
        return page
    }

    /// What the old host pushed again after each load and handshake: the theme, shortcuts, preview
    /// features, the in-session status toggle, the New Tab page's chats and closed items, the
    /// edited-files card's and the composer's settings, and a non-empty customization.
    @MainActor static func currentEvents(_ view: AgentPaneView) -> [AgentPageEvent] {
        var events: [AgentPageEvent] = []
        if let theme = AgentPageEvent.theme(view.themeTokens, surface: view.surfaceKind) { events.append(theme) }
        events.append(.shortcuts(view.shortcuts))
        events.append(.preview(view.previewFeatures))
        events.append(.sessionStatus(view.sessionStatus))
        events.append(AgentPaneSuggestedTasks.shared.event(for: view))
        events.append(.deviceChats(AgentPaneDeviceChat.shown(view.deviceChats, in: view)))
        events.append(view.recentlyClosed.event)
        events.append(AgentPaneNowPlaying.shared.event(for: view))
        events.append(.editedFiles(view.editedFiles))
        events.append(.composer(view.model.composer))
        events.append(.sidebarPreviewVariant(view.model.sidebarPreviewVariant))
        events.append(.diffColors(view.model.diffColors))
        events.append(.display(view.model.display))
        events.append(.toolCards(view.model.toolCards))
        events.append(view.model.tabRow.event)
        if !view.customization.isEmpty { events += AgentPageEvent.customization(view.customization) }
        return events
    }
}
