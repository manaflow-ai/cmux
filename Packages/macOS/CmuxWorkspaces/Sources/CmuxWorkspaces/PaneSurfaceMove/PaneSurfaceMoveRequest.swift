public import Foundation
public import Bonsplit

/// The typed payload describing where to move a surface, passed to
/// ``PaneLayoutControlling/move(surface:to:)``.
///
/// Replaces the legacy `AppDelegate.moveSurface(panelId:toWorkspace:targetPane:
/// targetIndex:splitTarget:focus:focusWindow:)` parameter list with one Sendable
/// value, so the surface-move coordinator and the app shim that conforms to the
/// seam speak a single typed request instead of a wide parameter list. Every
/// field mirrors the legacy parameter one-for-one, including its default, so the
/// move stays byte-faithful.
public struct PaneSurfaceMoveRequest: Sendable, Equatable {
    /// The split placement for the moved surface: where a `(orientation,
    /// insertFirst)` pair splits the resolved target pane, or `nil` to insert the
    /// surface into the target pane's tab strip. Mirrors the legacy
    /// `splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?`.
    public struct SplitTarget: Sendable, Equatable {
        /// The split orientation.
        public let orientation: SplitOrientation
        /// Whether the moved surface takes the first (leading/top) side of the
        /// split.
        public let insertFirst: Bool

        /// Creates a split target from its orientation and side.
        public init(orientation: SplitOrientation, insertFirst: Bool) {
            self.orientation = orientation
            self.insertFirst = insertFirst
        }
    }

    /// The panel/surface id being moved (legacy `panelId`).
    public let panelId: UUID
    /// The destination workspace id (legacy `toWorkspace targetWorkspaceId`).
    public let targetWorkspaceId: UUID
    /// The explicit destination pane, or `nil` to resolve the destination
    /// workspace's focused pane then its first pane (legacy `targetPane`).
    public let targetPane: PaneID?
    /// The destination tab-strip index, or `nil` to append (legacy `targetIndex`).
    public let targetIndex: Int?
    /// The split placement, or `nil` to insert into the pane (legacy `splitTarget`).
    public let splitTarget: SplitTarget?
    /// Whether to focus the moved surface after the move (legacy `focus`).
    public let focus: Bool
    /// Whether to also focus the destination window (legacy `focusWindow`).
    public let focusWindow: Bool

    /// Creates a surface-move request. Defaults mirror the legacy method's
    /// parameter defaults.
    public init(
        panelId: UUID,
        targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: SplitTarget? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) {
        self.panelId = panelId
        self.targetWorkspaceId = targetWorkspaceId
        self.targetPane = targetPane
        self.targetIndex = targetIndex
        self.splitTarget = splitTarget
        self.focus = focus
        self.focusWindow = focusWindow
    }
}
