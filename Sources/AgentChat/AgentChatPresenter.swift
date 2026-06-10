import AppKit
import CmuxAgentConversation
import Foundation

/// The shared action path for opening the agent chat view for a panel.
///
/// All entry points (menu item, future shortcut/command palette) call
/// ``AgentChatPresenter/presentForFocusedPanel()`` so the resolve-and-open flow
/// lives in one place. Resolution reads the restorable-session index and globs
/// the filesystem, so it runs off-main; the window is shown back on the main
/// actor.
@MainActor
struct AgentChatPresenter {
    /// The resolver used to map a panel to its transcript file.
    private let resolver: AgentChatTranscriptResolver

    /// Creates a presenter.
    ///
    /// - Parameter resolver: The transcript resolver to use.
    init(resolver: AgentChatTranscriptResolver = AgentChatTranscriptResolver()) {
        self.resolver = resolver
    }

    /// Resolves the focused panel's agent and presents its chat, or shows an
    /// alert when the focused panel has no recognizable agent session.
    func presentForFocusedPanel() {
        guard let manager = AppDelegate.shared?.activeTabManagerForCommands(),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            presentNoSessionAlert()
            return
        }
        let workspaceId = workspace.id
        let resolver = resolver
        // Capture the panel's persisted resume binding on the main actor so the
        // resolver can fall back to it when the live index has no entry (a
        // terminal restored after an app relaunch).
        let resumeBinding = workspace.surfaceResumeBinding(panelId: panelId)

        Task {
            // Loading the index and globbing the filesystem is IO; keep it off
            // the main actor, then present on the main actor.
            let resolution = await Task.detached(priority: .userInitiated) {
                let index = RestorableAgentSessionIndex.load()
                return resolver.resolve(
                    index: index,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    resumeBinding: resumeBinding
                )
            }.value

            guard let resolution else {
                presentNoSessionAlert()
                return
            }
            AgentChatWindowController.shared.present(for: resolution)
        }
    }

    /// Shows an alert explaining that the focused panel has no agent session.
    private func presentNoSessionAlert() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "agentChat.noSession.title",
            defaultValue: "No agent conversation"
        )
        alert.informativeText = String(
            localized: "agentChat.noSession.message",
            defaultValue: "Focus a terminal running Claude Code or Codex, then try View Chat again."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "agentChat.noSession.ok", defaultValue: "OK"))
        alert.runModal()
    }
}
