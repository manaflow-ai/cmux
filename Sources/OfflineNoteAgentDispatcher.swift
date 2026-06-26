import AppKit
import Foundation

/// Default ``OfflineNoteDispatching`` used by the running app.
///
/// When connectivity returns, each queued note is handed off to an agent by
/// staging its text into the **workspace it was captured in** (the macOS
/// TextBox composer of that workspace's focused terminal). Binding to the
/// capture workspace — rather than whatever workspace happens to be active at
/// flush time — keeps a note from landing in an unrelated workspace's composer
/// minutes later. Staging is **non-destructive** and made visible (the composer
/// shows the text, without stealing focus) so the user actually sees it; if the
/// capture workspace or its terminal is gone, dispatch fails closed and the note
/// stays queued for retry.
///
/// We deliberately stage into the composer rather than auto-submitting (e.g. via
/// the TextBox send path): this flush runs automatically in the background on
/// reconnect, and submitting note text into whatever terminal is focused could
/// run it unreviewed (e.g. as a shell command). Staging keeps delivery safe and
/// visible — the user reviews and submits. Directly injecting a prompt into a
/// freshly-created agent session would need the web-renderer session handshake
/// and is out of scope. The store talks to this type only through the protocol,
/// so delivery can be upgraded later (e.g. opt-in auto-submit) without touching
/// the queue.
@MainActor
final class OfflineNoteAgentDispatcher: OfflineNoteDispatching {
    /// Resolves the workspace a note should be delivered to. Injectable for tests.
    private let resolveWorkspace: @MainActor (UUID?) -> Workspace?

    init(resolveWorkspace: @escaping @MainActor (UUID?) -> Workspace? = OfflineNoteAgentDispatcher.defaultResolveWorkspace) {
        self.resolveWorkspace = resolveWorkspace
    }

    func dispatch(_ note: OfflineNote) async throws {
        guard let workspace = resolveWorkspace(note.workspaceID) else {
            throw OfflineNoteDispatchError.noActiveWorkspace
        }
        guard let terminal = workspace.focusedTerminalPanel else {
            throw OfflineNoteDispatchError.noComposerTarget
        }

        let existing = terminal.sessionTextBoxDraftSnapshot()
        var parts = existing?.parts ?? []
        if !parts.isEmpty {
            parts.append(.text("\n\n"))
        }
        parts.append(.text(note.text))

        // Show the composer so the staged note is visible (restoreSessionTextBoxDraft
        // marks it active without stealing first-responder focus).
        terminal.restoreSessionTextBoxDraft(
            SessionTextBoxInputDraftSnapshot(isActive: true, parts: parts)
        )
    }

    /// Default resolver: deliver only to the workspace the note was captured in.
    /// Searches every open window for that workspace; returns `nil` (fail closed)
    /// when it no longer exists. Legacy notes without a binding fall back to the
    /// active workspace.
    private static func defaultResolveWorkspace(_ workspaceID: UUID?) -> Workspace? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        guard let workspaceID else {
            return appDelegate.activeTabManagerForCommands()?.selectedWorkspace
        }
        for context in appDelegate.mainWindowContexts.values {
            if let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceID }) {
                return workspace
            }
        }
        return nil
    }
}
