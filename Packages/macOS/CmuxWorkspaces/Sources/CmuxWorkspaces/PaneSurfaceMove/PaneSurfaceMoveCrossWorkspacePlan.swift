public import Foundation
public import Bonsplit

/// The value-typed decisions ``PaneSurfaceMoveCoordinator`` hands the app shim
/// for the cross-workspace branch of a surface move.
///
/// The legacy cross-workspace tail of `AppDelegate.moveSurface` ran a fixed
/// sequence the moment a detach succeeded: attach the detached surface into the
/// destination pane (rolling back to the source pane/index on failure),
/// optionally split the destination pane (rolling back on failure), clean up the
/// now-empty source workspace, and focus the moved surface (focusing the
/// destination window and arming the cross-window reassert when requested). The
/// detached-surface transfer token is an app type that cannot cross the package
/// boundary, so the host owns that whole detach-scoped tail; the coordinator
/// hands it this plan, which carries only the value-typed decisions the tail
/// needs. `Sendable, Equatable` naming no app type.
public struct PaneSurfaceMoveCrossWorkspacePlan: Sendable, Equatable {
    /// The destination workspace id the surface attaches into.
    public let destinationWorkspaceId: UUID
    /// The destination window id (for focus/reassert), or `nil` when the move
    /// should not focus the destination window.
    public let destinationWindowId: UUID?
    /// The resolved destination pane the surface attaches into.
    public let targetPane: PaneID
    /// The destination tab-strip index, or `nil` to append.
    public let targetIndex: Int?
    /// The split placement applied after attach, or `nil` to leave the surface in
    /// the pane's tab strip.
    public let splitTarget: PaneSurfaceMoveRequest.SplitTarget?
    /// Whether to focus the moved surface after the move.
    public let focus: Bool

    /// Creates the cross-workspace plan from the resolved destination, split, and
    /// focus decisions.
    public init(
        destinationWorkspaceId: UUID,
        destinationWindowId: UUID?,
        targetPane: PaneID,
        targetIndex: Int?,
        splitTarget: PaneSurfaceMoveRequest.SplitTarget?,
        focus: Bool
    ) {
        self.destinationWorkspaceId = destinationWorkspaceId
        self.destinationWindowId = destinationWindowId
        self.targetPane = targetPane
        self.targetIndex = targetIndex
        self.splitTarget = splitTarget
        self.focus = focus
    }
}
