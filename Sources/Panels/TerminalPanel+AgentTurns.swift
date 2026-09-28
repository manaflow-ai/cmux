import AppKit
import SwiftUI

extension TerminalPanel {
    /// Opens the Turns popover for the agent session in this pane.
    func showAgentTurns(relativeTo anchor: NSView) {
        guard let agent = AgentTurnInterruptTarget.present(statusKeyedStates: containerAgentLifecycleStates) else {
            return
        }
        let kind: RestorableAgentKind = agent == .claudeCode ? .claude : .codex
        let surfaceID = id
        Task { @MainActor [weak self, weak anchor] in
            let locator = AgentPaneSessionLocator(agent: kind)
            let session = await Task.detached { locator.session(surfaceID: surfaceID) }.value
            var entry: SessionEntry?
            if let session {
                entry = await TerminalController.vaultEntry(agentID: agent.hookSource, sessionID: session.sessionID)
            }
            guard let self, let anchor, anchor.window != nil else { return }
            self.presentAgentTurnsPopover(agent: agent, entry: entry, relativeTo: anchor)
        }
    }

    private func presentAgentTurnsPopover(
        agent: AgentTurnInterruptTarget,
        entry: SessionEntry?,
        relativeTo anchor: NSView
    ) {
        let popover = NSPopover()
        popover.behavior = .transient
        let isRunning = AgentTurnInterruptTarget.resolve(statusKeyedStates: containerAgentLifecycleStates) != nil
        let view = AgentTurnsPopoverView(
            agentName: agent.displayName,
            entry: entry,
            isRunning: isRunning,
            onStop: { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.interruptAgentTurn(agent)
            },
            onEditPrompt: { [weak self, weak popover] text in
                popover?.performClose(nil)
                self?.putPromptInAgentInput(text)
            },
            onResume: { [weak self, weak popover] forked in
                popover?.performClose(nil)
                guard let self,
                      let tabManager = AppDelegate.shared?.workspaceContainingPanel(panelId: self.id)?.tabManager
                else { return }
                SessionEntryResumeCoordinator.resume(forked, tabManager: tabManager)
            },
            onDismiss: { [weak popover] in popover?.performClose(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// Pastes a past prompt into the agent's input, unsent, so it can be
    /// edited and sent again. Whatever the user had typed stays in front of it.
    func putPromptInAgentInput(_ text: String) {
        guard AgentTurnInterruptTarget.present(statusKeyedStates: containerAgentLifecycleStates) != nil else { return }
        _ = sendText(text)
    }
}
