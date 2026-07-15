import Foundation

enum CmuxNoteStoreError: Error, LocalizedError {
    case noteNotFound(slug: String)
    case corruptIndex(String)
    case untrustedNotesDirectory

    var errorDescription: String? {
        switch self {
        case .noteNotFound(let slug):
            return String(
                format: String(localized: "note.error.notFound", defaultValue: "Note not found: %@"),
                locale: .current,
                slug
            )
        case .corruptIndex(let detail):
            return String(
                format: String(localized: "note.error.corruptIndex", defaultValue: "Note index is invalid: %@"),
                locale: .current,
                detail
            )
        case .untrustedNotesDirectory:
            return String(
                localized: "note.error.untrustedNotesDirectory",
                defaultValue: "Notes are disabled for this project: .cmux/notes is a symlink."
            )
        }
    }
}
