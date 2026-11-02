/// Why an operation was refused (the daemon answers `invalid_params` or `not_found`).
public nonisolated enum BookmarkError: Error, Equatable, Sendable {
    case notFound(String)
    case invalidParent(String)
    case cycle
    case invalidURL
    case invalidKind
    case tooLarge
    case tooDeep
    /// No edit before the home daemon serves `bookmarks-v1`; `message` is the
    /// app's capability gate text (still starting, could not start, out of date).
    case unavailable(message: String)

    /// The gate's text when the edit waited on the home daemon, else nil.
    public static func unavailableMessage(_ error: any Error) -> String? {
        if case BookmarkError.unavailable(let message) = error { message } else { nil }
    }
}
