/// Decides whether cmux should run its visible-line command-click fallback.
///
/// Ghostty may consume a mouse release without dispatching a usable link, so
/// snapshot resolution remains a fallback for consumed releases. When the
/// synchronous open-URL callback already owned the same source reference, the
/// fallback is suppressed to prevent opening it twice.
public nonisolated struct TerminalCommandClickFallbackPolicy: Sendable {
    /// Creates the command-click fallback policy.
    public init() {}

    /// Returns whether the resolved visible-line reference should be opened.
    ///
    /// - Parameters:
    ///   - ghosttyConsumed: Whether Ghostty consumed the mouse release.
    ///   - isSnapshotResolution: Whether the fallback is anchored to the clicked
    ///     visible-line snapshot rather than Ghostty's cached QuickLook target.
    ///   - resolvedReference: The source reference resolved under the pointer.
    ///   - handledOpenURLReference: The source reference already handled by the
    ///     synchronous open-URL callback for this mouse release, if any.
    /// - Returns: `true` when cmux should open `resolvedReference` as a fallback.
    public func shouldOpenFallback(
        ghosttyConsumed: Bool,
        isSnapshotResolution: Bool,
        resolvedReference: TerminalPathResolution,
        handledOpenURLReference: TerminalPathResolution?
    ) -> Bool {
        guard handledOpenURLReference != resolvedReference else { return false }
        return !ghosttyConsumed || isSnapshotResolution
    }
}
