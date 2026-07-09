public import Foundation

/// The resolved target of a `workspace.action` request: the concrete workspace
/// and its owning window, after the app applied the legacy routing precedence
/// and the `workspace_id ?? selectedTabId` fallback.
///
/// The coordinator reads this once (the app-side witness performs the live
/// resolution and `v2ResolveWindowId`), then mints the `workspace_ref` /
/// `window_ref` from these ids and reuses them in every action payload — exactly
/// as the legacy `v2WorkspaceAction` resolved the workspace and window once and
/// reused them across each `finish(...)`.
public struct ControlWorkspaceActionTarget: Sendable, Equatable {
    /// The resolved workspace id.
    public let workspaceID: UUID
    /// The owning window id, or `nil` (legacy `v2ResolveWindowId` returned `nil`
    /// when no window owned the TabManager).
    public let windowID: UUID?

    /// Creates a resolved action target.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - windowID: The owning window id, or `nil`.
    public init(workspaceID: UUID, windowID: UUID?) {
        self.workspaceID = workspaceID
        self.windowID = windowID
    }
}
