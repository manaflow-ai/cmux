public import Foundation

/// A read-only snapshot of a workspace's pane layout for `pane.list`, as the
/// app target exposes it to ``ControlCommandCoordinator``.
///
/// Mirrors the legacy `v2PaneList` payload (workspace identity, the per-pane
/// rows, the resolved window, and the container frame) without the package
/// importing the app's workspace/Bonsplit types. The coordinator shapes the
/// final `JSONValue`, minting workspace/window refs itself.
public struct ControlPaneListSnapshot: Sendable, Equatable {
    /// The resolved workspace's identifier.
    public let workspaceID: UUID
    /// The window the workspace belongs to, if resolved.
    public let windowID: UUID?
    /// The panes, in `allPaneIds` order.
    public let panes: [ControlPaneSummary]
    /// The container's width, in pixels.
    public let containerWidth: Double
    /// The container's height, in pixels.
    public let containerHeight: Double

    /// Creates a pane-list snapshot.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace's identifier.
    ///   - windowID: The window the workspace belongs to, if resolved.
    ///   - panes: The panes, in order.
    ///   - containerWidth: The container's width, in pixels.
    ///   - containerHeight: The container's height, in pixels.
    public init(
        workspaceID: UUID,
        windowID: UUID?,
        panes: [ControlPaneSummary],
        containerWidth: Double,
        containerHeight: Double
    ) {
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.panes = panes
        self.containerWidth = containerWidth
        self.containerHeight = containerHeight
    }
}
