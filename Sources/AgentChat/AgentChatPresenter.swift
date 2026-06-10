import AppKit
import Bonsplit
import CmuxAgentConversation
import Foundation

/// The shared action path for opening the agent chat view for a panel.
///
/// All entry points (Window menu item, tab context menu, future
/// shortcut/command palette) share one resolve flow; only the presentation
/// differs (standalone window vs in-pane tab). Resolution reads the
/// restorable-session index and globs the filesystem, so it runs off-main; the
/// chat is shown back on the main actor.
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

    /// Resolves the focused panel's agent and presents its chat in the shared
    /// standalone window, or shows an alert when the focused panel has no
    /// recognizable agent session.
    func presentForFocusedPanel() {
        guard let manager = AppDelegate.shared?.activeTabManagerForCommands(),
              let workspace = manager.selectedWorkspace,
              let panelId = workspace.focusedPanelId else {
            presentNoSessionAlert()
            return
        }
        resolveThenPresent(
            workspaceId: workspace.id,
            panelId: panelId,
            resumeBinding: workspace.surfaceResumeBinding(panelId: panelId)
        ) { resolution in
            AgentChatWindowController.shared.present(for: resolution)
        }
    }

    /// Resolves a tab's panel and opens its chat as a tab next to the source
    /// terminal tab in the same pane, or shows an alert when the panel has no
    /// recognizable agent session.
    ///
    /// - Parameters:
    ///   - workspace: The workspace owning the tab.
    ///   - panelId: The right-clicked tab's panel id.
    ///   - anchorTabId: The right-clicked tab (the chat opens to its right).
    ///   - paneId: The pane hosting the tab.
    func presentAsTab(
        workspace: Workspace,
        panelId: UUID,
        anchorTabId: TabID,
        paneId: PaneID
    ) {
        resolveThenPresent(
            workspaceId: workspace.id,
            panelId: panelId,
            resumeBinding: workspace.surfaceResumeBinding(panelId: panelId)
        ) { [weak workspace] resolution in
            workspace?.openAgentChatTab(
                resolution: resolution,
                anchorTabId: anchorTabId,
                paneId: paneId
            )
        }
    }

    /// Resolves a panel's transcript off-main, then either runs `present` with
    /// the resolution or shows the no-session alert, on the main actor.
    ///
    /// The `resumeBinding` is captured on the main actor by the caller and lets
    /// the resolver fall back to it when the live session index has no entry
    /// (a terminal restored after an app relaunch).
    private func resolveThenPresent(
        workspaceId: UUID,
        panelId: UUID,
        resumeBinding: SurfaceResumeBindingSnapshot?,
        present: @escaping @MainActor (AgentChatTranscriptResolver.Resolution) -> Void
    ) {
        let resolver = resolver
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
            present(resolution)
        }
    }

    /// Shows an alert explaining that the panel has no agent session.
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
