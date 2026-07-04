import AppKit
import Foundation

/// Default ``OfflineNoteDispatching`` used by the running app.
///
/// When connectivity returns, each queued note is staged for review in the
/// **workspace it was captured in** (the macOS
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
/// run it unreviewed (e.g. as a shell command). Staging keeps the handoff safe and
/// visible — the user reviews and submits. Directly injecting a prompt into a
/// freshly-created agent session would need the web-renderer session handshake
/// and is out of scope. The store talks to this type only through the protocol,
/// so staging can be upgraded later (e.g. opt-in auto-submit) without touching
/// the queue.
@MainActor
final class OfflineNoteAgentDispatcher: OfflineNoteDispatching {
    /// Resolves the **visible** target workspace for a note. Injectable for tests.
    private let resolveVisibleWorkspace: @MainActor (UUID?) -> Workspace?

    init(resolveVisibleWorkspace: @escaping @MainActor (UUID?) -> Workspace? = OfflineNoteAgentDispatcher.defaultResolveVisibleWorkspace) {
        self.resolveVisibleWorkspace = resolveVisibleWorkspace
    }

    func dispatch(_ note: OfflineNote) async throws {
        // Deliver only when the captured workspace is currently visible (the
        // selected workspace in one of the open windows). Otherwise — no window
        // yet at launch, the workspace was closed, or the user switched away —
        // signal a transient condition so the store keeps the note pending and
        // retries when it becomes visible, rather than staging it into a hidden
        // draft the user would never notice (which would falsely read as "sent").
        guard let workspace = resolveVisibleWorkspace(note.workspaceID) else {
            throw OfflineNoteDispatchError.noActiveWorkspace
        }
        // The workspace is visible but has no focused terminal to stage into:
        // surfaced as a retryable failure (the user can focus a terminal + retry).
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

    /// Returns the captured workspace only when it is the workspace currently
    /// selected in one of the open windows, so the staged note is visible to the
    /// user. Returns `nil` (transient) when there is no window, the workspace is
    /// gone, or it is not the selected workspace. Legacy notes without a binding
    /// fall back to the active workspace.
    private static func defaultResolveVisibleWorkspace(_ workspaceID: UUID?) -> Workspace? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        guard let workspaceID else {
            return appDelegate.activeTabManagerForCommands()?.selectedWorkspace
        }
        for context in appDelegate.mainWindowContexts.values
        where context.tabManager.selectedWorkspace?.id == workspaceID {
            return context.tabManager.selectedWorkspace
        }
        return nil
    }
}
