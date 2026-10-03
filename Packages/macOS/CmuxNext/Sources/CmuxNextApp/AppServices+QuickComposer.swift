import CmuxNextAgentPane
import CmuxNextDesign

extension AppServices {
    /// The quick panel's chat is a standalone agent page in its compact
    /// layout (`surface: "quick"`); handed off, it opens as a tab in the
    /// focused pane of the frontmost main window.
    func makeQuickComposer() -> QuickComposerController {
        QuickComposerController(
            makeChat: { [unowned self] in
                guard self.agentTabs.canHostChat else { return nil }
                return self.agentTabs.standaloneView(seed: AgentPaneSeed(surface: .quick))
            },
            makeWindow: { QuickComposerPanel() },
            openInWindow: { [unowned self] session in self.openQuickChat(session: session) }
        )
    }

    /// The same placement as New Agent Chat: the focused pane of the active
    /// window. The user asked to go there, so the window comes forward and
    /// cmux activates.
    private func openQuickChat(session: String?) {
        guard let controller = windows.active, let pane = controller.focusedPane, let window = controller.window else {
            windows.reopenOrCreateWindow()
            return
        }
        pane.showAgentTab(agentTabs.open(in: pane.paneKey, of: pane.daemon.store, session: session))
        WindowActivation.show(window, .focus)
    }
}
