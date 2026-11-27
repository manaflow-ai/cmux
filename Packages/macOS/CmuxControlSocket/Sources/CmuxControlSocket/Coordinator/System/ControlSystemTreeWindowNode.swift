internal import Foundation

/// One window row of the `system.tree` snapshot (the legacy
/// `v2TreeWindowNode` dictionary, minus the coordinator-minted refs).
///
/// Reuses ``ControlWindowSummary`` as the window header so the window identity
/// fields have one source of truth with the window domain.
public struct ControlSystemTreeWindowNode: Sendable, Equatable {
    /// The window's identity/visibility header.
    public let summary: ControlWindowSummary
    /// The window's index in the full main-window summary enumeration (kept
    /// absolute even when a single window is filtered, as the legacy body did).
    public let index: Int
    /// The window's workspace nodes (all workspaces, or the single filtered
    /// one).
    public let workspaces: [ControlSystemTreeWorkspaceNode]

    /// Creates a window node.
    ///
    /// - Parameters:
    ///   - summary: The window's identity/visibility header.
    ///   - index: The absolute window enumeration index.
    ///   - workspaces: The window's workspace nodes.
    public init(
        summary: ControlWindowSummary,
        index: Int,
        workspaces: [ControlSystemTreeWorkspaceNode]
    ) {
        self.summary = summary
        self.index = index
        self.workspaces = workspaces
    }
}
