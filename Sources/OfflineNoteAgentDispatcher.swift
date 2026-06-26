import AppKit
import Foundation

/// Default ``OfflineNoteDispatching`` used by the running app.
///
/// When connectivity returns, each queued note is handed off to an agent by
/// staging its text into the active workspace's agent composer (the macOS
/// TextBox). Staging is **non-destructive**: any text the user already has in
/// the composer is preserved and successive notes accumulate, so flushing a
/// backlog drops the whole queue in front of the agent for the user to review
/// and send.
///
/// Staging into the composer is the cleanest hand-off cmux supports natively —
/// directly injecting a first prompt into a freshly-created agent session
/// requires the web-renderer session handshake and is intentionally out of
/// scope here. The store talks to this type only through the protocol, so that
/// delivery can be upgraded later without touching the queue.
@MainActor
final class OfflineNoteAgentDispatcher: OfflineNoteDispatching {
    /// Resolves the workspace that should receive notes. Injectable for tests.
    private let resolveWorkspace: @MainActor () -> Workspace?

    init(resolveWorkspace: @escaping @MainActor () -> Workspace? = {
        AppDelegate.shared?.activeTabManagerForCommands()?.selectedWorkspace
    }) {
        self.resolveWorkspace = resolveWorkspace
    }

    func dispatch(_ note: OfflineNote) async throws {
        guard let workspace = resolveWorkspace() else {
            throw OfflineNoteDispatchError.noActiveWorkspace
        }
        guard let terminal = terminalPanel(in: workspace) else {
            throw OfflineNoteDispatchError.noComposerTarget
        }

        let existing = terminal.sessionTextBoxDraftSnapshot()
        var parts = existing?.parts ?? []
        if !parts.isEmpty {
            parts.append(.text("\n\n"))
        }
        parts.append(.text(note.text))

        // Preserve the composer's current visibility — staging a backlog should
        // not steal focus or pop the TextBox open behind the user's back.
        let isActive = existing?.isActive ?? false
        terminal.restoreSessionTextBoxDraft(
            SessionTextBoxInputDraftSnapshot(isActive: isActive, parts: parts)
        )
    }

    private func terminalPanel(in workspace: Workspace) -> TerminalPanel? {
        if let focused = workspace.focusedTerminalPanel {
            return focused
        }
        return workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
    }
}
