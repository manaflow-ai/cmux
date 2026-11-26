/// The manual loader key state before and after a `workspace_loading` toggle,
/// reported back to the caller (e.g. `before=ON;after=OFF`).
public struct ControlSidebarWorkspaceLoadingState: Sendable, Equatable {
    /// Whether this manual loader key was running before the toggle.
    public let before: Bool

    /// Whether this manual loader key is running after the toggle.
    public let after: Bool

    /// A human-readable failure reason when the requested toggle could not be
    /// applied. The v1 line protocol maps this to `ERROR: <reason>`.
    public let failureReason: String?

    /// Creates a before/after pair for one `workspace_loading` toggle.
    ///
    /// - Parameters:
    ///   - before: Spinner state before the change.
    ///   - after: Spinner state after the change.
    ///   - failureReason: A failure reason when no state change was possible.
    public init(before: Bool, after: Bool, failureReason: String? = nil) {
        self.before = before
        self.after = after
        self.failureReason = failureReason
    }
}
