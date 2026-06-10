import Foundation

/// Routes composer drafts from the agent chat view to the terminal panel the
/// conversation belongs to.
///
/// This is the app-layer half of the composer wiring: the package view only
/// sees a `ChatComposerActions` closure built from this router, never a store
/// reference. Sending reuses the shared terminal input entrypoints
/// (`TerminalPanel.sendText` / `sendNamedKey`) that the socket `send` path and
/// the mobile host already go through.
///
/// Multi-line drafts are submitted paste-style: the body goes through the
/// terminal's paste path (`ghostty_surface_text`, a bracketed paste when the
/// TUI has it enabled) so embedded newlines land as literal newlines in the
/// agent's input box instead of CR-fragmenting into premature submits, then a
/// single Return key event submits — the same shape the iOS composer uses.
@MainActor
struct AgentChatTerminalSendRouter {
    /// The workspace owning the target panel.
    let workspaceId: UUID

    /// The terminal panel running the agent.
    let panelId: UUID

    /// Sends one composed message to the target terminal.
    ///
    /// - Parameter text: The draft text (already trimmed by the composer).
    /// - Returns: `true` when both the body and the submitting Return were
    ///   accepted (sent, or queued for a hibernated surface); `false` when the
    ///   panel is gone or the input was rejected.
    func send(_ text: String) -> Bool {
        guard let panel = targetPanel() else { return false }
        guard panel.sendText(text) else { return false }
        return panel.sendNamedKey("enter")
    }

    /// Resolves the target terminal panel, if it still exists in any window.
    private func targetPanel() -> TerminalPanel? {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        return workspace.terminalPanel(for: panelId)
    }
}
