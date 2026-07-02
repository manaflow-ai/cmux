import Foundation

/// Failure reasons surfaced by the default ``OfflineNoteDispatching`` agent
/// dispatcher. `LocalizedError` so the stored `lastError` reads cleanly in the
/// notes list.
enum OfflineNoteDispatchError: LocalizedError, Equatable {
    /// No cmux window/workspace is available to receive the note.
    case noActiveWorkspace
    /// The active workspace has no focused agent surface to stage the note into.
    case noComposerTarget

    var errorDescription: String? {
        switch self {
        case .noActiveWorkspace:
            return String(
                localized: "offlineNotes.dispatch.error.noActiveWorkspace",
                defaultValue: "Open a cmux window to send this note to an agent."
            )
        case .noComposerTarget:
            return String(
                localized: "offlineNotes.dispatch.error.noComposerTarget",
                defaultValue: "Focus a terminal so cmux can send this note to its agent."
            )
        }
    }
}
