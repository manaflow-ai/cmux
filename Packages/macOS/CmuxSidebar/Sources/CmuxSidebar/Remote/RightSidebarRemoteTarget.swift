public import Foundation

/// Identifies which window's right sidebar a remote `right_sidebar` command
/// addresses. An empty target (`windowId` and `workspaceId` both `nil`) means
/// the active main window.
public struct RightSidebarRemoteTarget: Equatable, Sendable {
    /// The window id to address, or `nil` to fall back to `workspaceId`/active.
    public var windowId: UUID?
    /// A workspace id whose owning window is addressed, or `nil`.
    public var workspaceId: UUID?

    /// Creates a target. With both ids `nil` the command addresses the active
    /// main window.
    public init(windowId: UUID? = nil, workspaceId: UUID? = nil) {
        self.windowId = windowId
        self.workspaceId = workspaceId
    }

    /// `true` when neither id is set, i.e. the command targets the active window.
    public var isActiveTarget: Bool {
        windowId == nil && workspaceId == nil
    }
}
