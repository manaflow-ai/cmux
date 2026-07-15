import Foundation

/// Errors thrown by ``NotesTreeStorage`` mutations.
enum NotesTreeStorageError: Error, LocalizedError {
    case sourceMissing(String)
    case invalidMove
    case invalidName
    case writeFailed(String)
    case untrustedNotesDirectory

    var errorDescription: String? {
        switch self {
        case .untrustedNotesDirectory:
            return String(
                localized: "note.error.untrustedNotesDirectory",
                defaultValue: "Notes are disabled for this project: .cmux/notes is a symlink."
            )
        case .sourceMissing(let path):
            return String(
                format: String(localized: "notes.error.sourceMissing", defaultValue: "Note no longer exists: %@"),
                locale: .current,
                path
            )
        case .invalidMove:
            return String(localized: "notes.error.invalidMove", defaultValue: "Cannot move a folder into itself")
        case .invalidName:
            return String(localized: "notes.error.invalidName", defaultValue: "That name can't be used")
        case .writeFailed(let path):
            return String(
                format: String(localized: "notes.error.writeFailed", defaultValue: "Could not create note: %@"),
                locale: .current,
                path
            )
        }
    }
}
