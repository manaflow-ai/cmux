import Foundation

enum NameSanitizer {
    enum Error: LocalizedError {
        case empty
        case containsPathSeparator
        case containsParentTraversal

        var errorDescription: String? {
            switch self {
            case .empty:
                return String(localized: "nameSanitizer.error.empty", defaultValue: "Name cannot be empty")
            case .containsPathSeparator:
                return String(
                    localized: "nameSanitizer.error.pathSeparator",
                    defaultValue: "Name cannot contain path separators"
                )
            case .containsParentTraversal:
                return String(
                    localized: "nameSanitizer.error.parentTraversal",
                    defaultValue: "Name cannot contain '..'"
                )
            }
        }
    }

    /// Validates a name is safe for use as a filename component.
    /// Rejects directory traversal vectors: empty, contains / or \, contains .., contains :
    /// Does NOT enforce general filename aesthetics (Unicode, control chars, length).
    static func sanitize(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.empty }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains(":") else {
            throw Error.containsPathSeparator
        }
        guard !trimmed.contains("..") else { throw Error.containsParentTraversal }
        return trimmed
    }
}
