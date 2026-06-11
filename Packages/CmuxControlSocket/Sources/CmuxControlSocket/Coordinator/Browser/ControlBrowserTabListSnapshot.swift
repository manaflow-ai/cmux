public import Foundation

/// The app snapshot behind `browser.tab.list`.
public struct ControlBrowserTabListSnapshot: Sendable, Equatable {
    /// The resolved workspace id.
    public let workspaceID: UUID
    /// The workspace's focused panel id, if any (the payload's `surface_id`).
    public let focusedSurfaceID: UUID?
    /// The workspace's browser tabs, in panel order.
    public let tabs: [ControlBrowserTabSummary]

    /// Creates a tab-list snapshot.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace id.
    ///   - focusedSurfaceID: The focused panel id, if any.
    ///   - tabs: The browser tabs, in panel order.
    public init(workspaceID: UUID, focusedSurfaceID: UUID?, tabs: [ControlBrowserTabSummary]) {
        self.workspaceID = workspaceID
        self.focusedSurfaceID = focusedSurfaceID
        self.tabs = tabs
    }
}
