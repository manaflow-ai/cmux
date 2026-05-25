import AppKit
import Foundation

/// Maps livesh's documented exit codes (66 = shell lost, 69 = daemon unavailable) to user-visible
/// banners and pane-disposition decisions. Called from the Ghostty `SHOW_CHILD_EXITED` callback
/// in `GhosttyTerminalView.swift` before the normal child-exit close path runs.
///
/// Returns `true` when this handler took over the pane lifecycle (showed UI + scheduled the
/// appropriate follow-up). Returns `false` when the caller should fall through to the standard
/// `closePanelAfterChildExited` flow.
@MainActor
enum LiveShellChildExitHandler {
    private static var suppressedShellLostSessionIds: Set<String> = []

    /// Mark a session id so the next `shellLost` exit for it closes silently. Used when the user
    /// triggered the kill themselves (palette/CLI) — otherwise they'd see a misleading
    /// "daemon may have crashed" modal right after their intentional kill.
    static func suppressNextShellLostAlert(forSessionId sessionId: String) {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        suppressedShellLostSessionIds.insert(trimmed)
    }

    /// Returns true if the exit was handled as a livesh-specific event (caller should NOT also
    /// close the pane). Returns false if the caller should run the default close path.
    static func handleIfRelevant(
        workspace: Workspace,
        panelId: UUID,
        exitCode: Int32
    ) -> Bool {
        guard exitCode == LiveShellExitCode.shellLost || exitCode == LiveShellExitCode.daemonUnavailable else {
            return false
        }
        guard let binding = workspace.surfaceResumeBindingsByPanelId[panelId],
              binding.kind == "livesh" else {
            return false
        }

        if exitCode == LiveShellExitCode.shellLost,
           let sessionId = binding.checkpointId,
           suppressedShellLostSessionIds.remove(sessionId) != nil {
            // User killed this session intentionally — drop the binding and close silently.
            workspace.surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
            closePane(panelId: panelId, workspace: workspace)
            return true
        }

        switch exitCode {
        case LiveShellExitCode.shellLost:
            presentShellLostAlert(sessionId: binding.checkpointId, panelId: panelId, workspace: workspace)
        case LiveShellExitCode.daemonUnavailable:
            presentDaemonUnavailableAlert(panelId: panelId, workspace: workspace)
        default:
            return false
        }
        return true
    }

    private static func presentShellLostAlert(
        sessionId: String?,
        panelId: UUID,
        workspace: Workspace
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "liveShell.exit.shellLost.title",
            defaultValue: "Live Shell Is Gone"
        )
        var body = String(
            localized: "liveShell.exit.shellLost.body",
            defaultValue: "The live shell no longer exists. The daemon may have crashed or the shell may have been killed externally."
        )
        if let sessionId, !sessionId.isEmpty {
            body += "\n\n" + sessionLabel(sessionId)
        }
        alert.informativeText = body
        alert.addButton(withTitle: String(
            localized: "liveShell.exit.shellLost.button.close",
            defaultValue: "Close Pane"
        ))
        // Drop the stale resume binding — it points at a session that no longer exists.
        workspace.surfaceResumeBindingsByPanelId.removeValue(forKey: panelId)
        _ = alert.runModal()
        closePane(panelId: panelId, workspace: workspace)
    }

    private static func presentDaemonUnavailableAlert(
        panelId: UUID,
        workspace: Workspace
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "liveShell.exit.daemonUnavailable.title",
            defaultValue: "livesh Daemon Unavailable"
        )
        alert.informativeText = String(
            localized: "liveShell.exit.daemonUnavailable.body",
            defaultValue: "Could not reach the livesh daemon (liveshd). The pane will close. Restart liveshd by opening any new terminal with the livesh backend, or check `liveshctl status` in another terminal."
        )
        alert.addButton(withTitle: String(
            localized: "liveShell.exit.daemonUnavailable.button.close",
            defaultValue: "Close Pane"
        ))
        _ = alert.runModal()
        closePane(panelId: panelId, workspace: workspace)
    }

    private static func sessionLabel(_ sessionId: String) -> String {
        let prefix = String(
            localized: "liveShell.sessionLabelPrefix",
            defaultValue: "Session:"
        )
        return "\(prefix) \(sessionId)"
    }

    private static func closePane(panelId: UUID, workspace: Workspace) {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: workspace.id) ?? app.tabManager,
              workspace.panels[panelId] != nil else {
            return
        }
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panelId)
    }
}
