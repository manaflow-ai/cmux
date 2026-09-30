public import Foundation

/// The outcome of `sidebar.group_by` against the window the routing selectors
/// resolve, keeping the same two routing failures as `window.current`.
public enum ControlSidebarGroupByResolution: Sendable, Equatable {
    /// The window's mode after the call (the raw `manual`, `host` or `status`).
    case resolved(windowID: UUID, mode: String)
    /// No TabManager resolved from the routing selectors.
    case tabManagerUnavailable
    /// A TabManager resolved but its window id could not be found.
    case windowNotFound
    /// The requested mode is not one the app knows. The window is unchanged.
    case invalidMode
}
