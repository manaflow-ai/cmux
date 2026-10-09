import CmuxNextAgentPane
import CmuxNextDesign

extension AppServices {
    /// The quick panel's chat is a standalone agent page in its compact
    /// layout (`surface: "quick"`); handed off, it opens as a tab in the
    /// focused pane of the frontmost main window.
    func makeQuickComposer() -> QuickComposerController {
        QuickComposerController(
            makeChat: { [weak self] in
                guard let self, self.agentTabs.canHostChat else { return nil }
                return self.agentTabs.standaloneView(seed: AgentPaneSeed(surface: .quick))
            },
            makeWindow: { QuickComposerPanel() },
            openInWindow: { [weak self] session in self?.openQuickChat(session: session) }
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
}
