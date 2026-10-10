import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign

extension AppServices {
    /// Start Agent's chat is a standalone agent page in its compact layout
    /// (`surface: "quick"`). Its folder picker lists the New Tab page's
    /// recent projects. Started with Return it goes to the sidebar in a new
    /// workspace, in the background; with ⌘Return it opens as a tab in the
    /// focused pane of the frontmost main window.
    func makeQuickComposer() -> QuickComposerController {
        QuickComposerController(
            makeChat: { [weak self] in
                guard let self, self.agentTabs.canHostChat,
                      let chat = self.agentTabs.standaloneView(seed: AgentPaneSeed(surface: .quick)) else { return nil }
                let projects = NewTabPage.handler(self, cwd: nil) { _, _ in }
                chat.model.onListProjects = { query in await projects.listProjects(query) }
                return chat
            },
            makeWindow: { QuickComposerPanel() },
            openInWindow: { [weak self] session in self?.openQuickChat(session: session) ?? false },
            startInBackground: { [weak self] start in await self?.startQuickChatInBackground(start) ?? false }
        )
    }

    /// The same placement as New Agent Chat: the focused pane of the active
    /// window. The user asked to go there, so the window comes forward and
    /// cmux activates. False when no window has a focused pane: a window is
    /// reopened, and the chat stays in the panel until it can move.
    private func openQuickChat(session: String?) -> Bool {
        guard let controller = windows.active, let pane = controller.focusedPane, let window = controller.window else {
            windows.reopenOrCreateWindow()
            return false
        }
        pane.openAgentTab(session: session)
        WindowActivation.show(window, .focus)
        return true
    }

    /// A new workspace in the sidebar whose selected tab is the started chat
    /// (`agent.openSessionWorkspace`'s path): nothing takes focus or
    /// switches workspaces. False when the daemon is offline or the
    /// workspace or its tab could not be made.
    private func startQuickChatInBackground(_ start: AgentPaneQuickStart) async -> Bool {
        let work: ActionWork
        do {
            work = try AgentSessionWorkspace.open(session: start.sessionId, name: start.name, cwd: start.cwd, services: self)
        } catch {
            daemon.logger.error("start agent: background start refused: \(String(describing: error), privacy: .public)")
            return false
        }
        registry.track(work)
        if let failure = await work.value {
            daemon.logger.error("start agent: background start failed: \(failure.message, privacy: .public)")
            return false
        }
        return true
    }
}
