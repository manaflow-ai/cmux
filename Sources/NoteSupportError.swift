import Foundation

enum NoteSupportError: Error, CustomStringConvertible, LocalizedError {
    case invalidSlug(String)
    case notRegularFile

    var description: String {
        switch self {
        case .invalidSlug(let reason):
            return String(
                format: String(localized: "note.error.invalidSlug", defaultValue: "Invalid note slug: %@"),
                locale: .current,
                reason
            )
        case .notRegularFile:
            return String(localized: "note.error.notRegularFile", defaultValue: "Note path is not a regular file")
        }
    }

    var errorDescription: String? { description }
}
