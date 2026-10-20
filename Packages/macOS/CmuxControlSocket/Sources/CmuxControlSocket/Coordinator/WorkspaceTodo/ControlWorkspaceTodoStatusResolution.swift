public import Foundation

/// The app-side resolution of `workspace.status.get` / `workspace.status.set`.
public enum ControlWorkspaceTodoStatusResolution: Sendable {
    /// No TabManager resolved from the routing selectors.
    case tabManagerUnavailable
    /// The workspace was not found (or no workspace is selected).
    case notFound
    /// The `status` param was not a known lane (the string is echoed back).
    case invalidStatus(String)
    /// The status snapshot after the read/mutation, with the owning window.
    case resolved(windowID: UUID?, status: ControlWorkspaceTodoStatusSnapshot)
}
