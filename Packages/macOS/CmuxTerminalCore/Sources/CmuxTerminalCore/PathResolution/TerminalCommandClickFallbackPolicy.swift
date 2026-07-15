/// Decides whether cmux should run its visible-line command-click fallback.
///
/// Ghostty may consume a mouse release without dispatching a usable link, so
/// snapshot resolution remains a fallback for consumed releases. When the
/// synchronous open-URL callback already owned the same resolved file, the
/// fallback is suppressed to prevent opening it twice.
public nonisolated struct TerminalCommandClickFallbackPolicy: Sendable {
    /// Creates the command-click fallback policy.
    public init() {}

    /// Returns whether the resolved visible-line path should be opened.
    public func shouldOpenFallback(
        ghosttyConsumed: Bool,
        isSnapshotResolution: Bool,
        resolvedPath: String,
        handledOpenURLPath: String?
    ) -> Bool {
        guard handledOpenURLPath != resolvedPath else { return false }
        return !ghosttyConsumed || isSnapshotResolution
    }
}
