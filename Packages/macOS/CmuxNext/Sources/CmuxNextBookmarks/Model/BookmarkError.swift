/// Why an operation was refused (the daemon answers `invalid_params` or `not_found`).
public nonisolated enum BookmarkError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidParent(String)
    case cycle
    case invalidURL
    case invalidKind
    case tooLarge
    case tooDeep
    /// Any other refusal of the rules (a malformed id, profile, time or import).
    case invalid(String)
    /// The app FFI did not answer.
    case unavailable

    /// The refusal cmux-bookmarks-core names by its `reason`.
    init(reason: String, message: String) {
        switch reason {
        case "not_found": self = .notFound(message)
        case "invalid_parent": self = .invalidParent(message)
        case "cycle": self = .cycle
        case "invalid_url": self = .invalidURL
        case "invalid_kind": self = .invalidKind
        case "too_large": self = .tooLarge
        case "too_deep": self = .tooDeep
        default: self = .invalid(message)
        }
    }
}
