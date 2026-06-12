import AppKit
import Foundation

/// The shared action path for opening the agent chat pane for a panel.
///
/// All entry points route through one resolve-and-open flow: the Window menu,
/// command palette, and keyboard shortcut call
/// ``AgentChatPresenter/presentForFocusedPanel()``, while the terminal context
/// menu and the `surface.agent_chat.open` socket verb (the `cmux agent-chat`
/// CLI command) target an explicit panel via
/// ``AgentChatPresenter/present(panelId:in:manager:)``. Resolution reads the
/// restorable-session index and globs the filesystem, so it runs off-main; the
/// pane is opened back on the main actor as a split next to the panel it
/// mirrors.
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

    /// Resolves the focused panel's agent and opens (or focuses) its chat
    /// pane, or shows an alert when the focused panel has no recognizable
    /// agent session.
    func presentForFocusedPanel() {
#if DEBUG
        cmuxDebugLog("agentChat.present.enter")
#endif
        guard let manager = AppDelegate.shared?.activeTabManagerForCommands() else {
#if DEBUG
            cmuxDebugLog("agentChat.present.guard reason=noTabManager")
#endif
            presentNoSessionAlert()
            return
        }
        guard let workspace = manager.selectedWorkspace else {
#if DEBUG
            cmuxDebugLog("agentChat.present.guard reason=noSelectedWorkspace")
#endif
            presentNoSessionAlert()
            return
        }
        guard let panelId = workspace.focusedPanelId else {
#if DEBUG
            cmuxDebugLog("agentChat.present.guard reason=noFocusedPanel ws=\(workspace.id.uuidString.prefix(5))")
#endif
            presentNoSessionAlert()
            return
        }
        present(panelId: panelId, in: workspace, manager: manager)
    }

    /// Resolves a specific panel's agent and opens (or focuses) its chat pane,
    /// or shows an alert when the panel has no recognizable agent session.
    ///
    /// This is the shared resolve-then-present body behind every entry point;
    /// callers that target a non-focused panel (terminal context menu, the
    /// `surface.agent_chat.open` socket verb) call it directly.
    ///
    /// - Parameters:
    ///   - panelId: The panel whose agent conversation should be shown.
    ///   - workspace: The workspace owning `panelId`.
    ///   - manager: The TabManager owning `workspace`.
    func present(panelId: UUID, in workspace: Workspace, manager: TabManager) {
        if let chatPanel = workspace.panels[panelId] as? AgentChatPanel {
            // The target panel is itself a chat pane; it is already open.
#if DEBUG
            cmuxDebugLog("agentChat.present.skip reason=chatPanelTargeted panel=\(panelId.uuidString.prefix(5))")
#endif
            workspace.focusPanel(chatPanel.id)
            return
        }
        let workspaceId = workspace.id
        let resolver = resolver
        // The hook-session index is keyed by the ids hooks last reported; a
        // freshly restored panel misses there, so capture the workspace's own
        // restored-agent snapshot (the resume path's source) as the fallback.
        let restoredSnapshot = workspace.restoredAgentSnapshotForAgentChat(panelId: panelId)
        // Capture the panel's persisted resume binding on the main actor so the
        // resolver can fall back to it when both the live index and the
        // restored snapshot miss (a terminal restored after an app relaunch).
        let resumeBinding = workspace.surfaceResumeBinding(panelId: panelId)
#if DEBUG
        cmuxDebugLog(
            "agentChat.present.resolve.start ws=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) restoredSnapshot=\(restoredSnapshot != nil ? 1 : 0) " +
            "resumeBinding=\(resumeBinding != nil ? 1 : 0)"
        )
#endif

        Task {
            // Loading the index and globbing the filesystem is IO; keep it off
            // the main actor, then open the pane on the main actor.
            let resolution = await Task.detached(priority: .userInitiated) {
                resolver.resolve(
                    index: RestorableAgentSessionIndex.load(),
                    restoredSnapshot: restoredSnapshot,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    resumeBinding: resumeBinding
                )
            }.value

            guard let resolution else {
#if DEBUG
                cmuxDebugLog(
                    "agentChat.present.resolve.miss ws=\(workspaceId.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5))"
                )
#endif
                presentNoSessionAlert()
                return
            }
            guard resolution.transcriptURL != nil else {
                // The session is indexed but its transcript file is gone
                // (cleanup, remote-only session); an empty chat pane would
                // just render the subscribe error, so explain instead.
#if DEBUG
                cmuxDebugLog(
                    "agentChat.present.resolve.noTranscript provider=\(resolution.provider.rawValue) " +
                    "session=\(resolution.sessionId.prefix(8))"
                )
#endif
                presentNoTranscriptAlert()
                return
            }
#if DEBUG
            cmuxDebugLog(
                "agentChat.present.resolve.hit provider=\(resolution.provider.rawValue) " +
                "session=\(resolution.sessionId.prefix(8)) " +
                "transcriptFound=\(resolution.transcriptURL != nil ? 1 : 0)"
            )
#endif
            guard manager.tabs.contains(where: { $0.id == workspaceId }) else {
#if DEBUG
                cmuxDebugLog("agentChat.present.guard reason=workspaceClosedDuringResolve")
#endif
                return
            }
            let opened = workspace.openOrFocusAgentChatSplit(from: panelId, resolution: resolution)
#if DEBUG
            cmuxDebugLog("agentChat.present.open result=\(opened == nil ? "failed" : "ok")")
#endif
            if opened == nil {
                NSSound.beep()
            }
        }
    }

    /// Shows an alert explaining that the focused panel has no agent session.
    private func presentNoSessionAlert() {
#if DEBUG
        cmuxDebugLog("agentChat.present.alert reason=noSession")
#endif
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

    /// Shows an alert explaining that the panel's agent session has no
    /// transcript file on disk (so there is nothing for the chat to render).
    private func presentNoTranscriptAlert() {
#if DEBUG
        cmuxDebugLog("agentChat.present.alert reason=noTranscript")
#endif
        let alert = NSAlert()
        alert.messageText = String(
            localized: "agentChat.noSession.title",
            defaultValue: "No agent conversation"
        )
        alert.informativeText = String(
            localized: "agentChat.error.noTranscript",
            defaultValue: "No transcript file was found for this agent session."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "agentChat.noSession.ok", defaultValue: "OK"))
        alert.runModal()
    }
}
