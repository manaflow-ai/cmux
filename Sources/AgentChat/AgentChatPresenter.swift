import AppKit
import Foundation

/// The shared action path for opening the agent chat pane for a panel.
///
/// All entry points (command palette, Window menu) call
/// ``AgentChatPresenter/presentForFocusedPanel()`` so the resolve-and-open flow
/// lives in one place. Resolution reads the restorable-session index and globs
/// the filesystem, so it runs off-main; the pane is opened back on the main
/// actor as a split next to the panel it mirrors.
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
        if let chatPanel = workspace.panels[panelId] as? AgentChatPanel {
            // The chat pane itself is focused; it is already open.
#if DEBUG
            cmuxDebugLog("agentChat.present.skip reason=chatPanelFocused panel=\(panelId.uuidString.prefix(5))")
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
#if DEBUG
        cmuxDebugLog(
            "agentChat.present.resolve.start ws=\(workspaceId.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) restoredSnapshot=\(restoredSnapshot != nil ? 1 : 0)"
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
                    panelId: panelId
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
}
