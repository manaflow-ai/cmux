internal import Foundation

/// One window row of a `system.top` / `system.memory` snapshot (the legacy
/// `v2TopWindowNode` dictionary, minus the coordinator-minted refs and the
/// process-annotation fields the nonisolated `system.top` pipeline adds
/// afterward).
///
/// Reuses ``ControlWindowSummary`` as the window header so the window identity
/// fields have one source of truth with the window domain, mirroring
/// ``ControlSystemTreeWindowNode``. The app target builds these from live
/// `AppDelegate` / `TabManager` state behind ``ControlSystemContext``; the
/// coordinator shapes them into the byte-faithful payload dictionary that the
/// worker-lane annotation pipeline then enriches.
public struct ControlSystemTopWindowNode: Sendable, Equatable {
    /// The window's identity/visibility header.
    public let summary: ControlWindowSummary
    /// The window's index in the main-window summary enumeration.
    public let index: Int
    /// The window's workspace nodes (all workspaces, or the single filtered
    /// one). The `workspace_count` payload field reflects this node count, not
    /// the summary's total, matching the legacy `v2TopWindowNode` body.
    public let workspaces: [ControlSystemTopWorkspaceNode]

    /// Creates a window node.
    ///
    /// - Parameters:
    ///   - summary: The window's identity/visibility header.
    ///   - index: The window's enumeration index.
    ///   - workspaces: The window's workspace nodes.
    public init(
        summary: ControlWindowSummary,
        index: Int,
        workspaces: [ControlSystemTopWorkspaceNode]
    ) {
        self.summary = summary
        self.index = index
        self.workspaces = workspaces
    }
}
