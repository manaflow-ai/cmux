public import Foundation

/// The manual loader key state before and after a `workspace_loading` toggle,
/// reported back to the caller (e.g. `before=ON;after=OFF`).
public struct ControlSidebarWorkspaceLoadingState: Sendable, Equatable {
    /// Whether this manual loader key was running before the toggle.
    public let before: Bool

    /// Whether this manual loader key is running after the toggle.
    public let after: Bool

    /// Creates a before/after pair for one `workspace_loading` toggle.
    ///
    /// - Parameters:
    ///   - before: Spinner state before the change.
    ///   - after: Spinner state after the change.
    public init(before: Bool, after: Bool) {
        self.before = before
        self.after = after
    }
}
