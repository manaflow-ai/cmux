public import Foundation
public import Bonsplit

/// The workspace-side seam ``SurfaceLifecycleCoordinator`` reads (and, for the
/// one divider write, drives) the live split tree through.
///
/// **Why a synchronous read-only/one-write protocol and not value snapshots.**
/// Every resolver lifted into the coordinator
/// (``SurfaceLifecycleCoordinator/paneId(forPanelId:)``,
/// ``SurfaceLifecycleCoordinator/indexInPane(forPanelId:)``,
/// ``SurfaceLifecycleCoordinator/preferredRightSideTargetPane(fromPanelId:)``,
/// ``SurfaceLifecycleCoordinator/topRightBrowserReusePane()``,
/// ``SurfaceLifecycleCoordinator/applyInitialSplitDividerPosition(_:sourcePaneId:newPaneId:)``)
/// is one MainActor turn that must observe the authoritative `BonsplitController`
/// split tree, pane list, and per-pane tab order exactly as the legacy
/// `Workspace` method bodies did. The split tree and tab membership are owned by
/// `BonsplitController`; the surface-id-to-panel-id mapping is owned by the
/// workspace. The coordinator reads them through this seam so it never holds the
/// app-target `Workspace`, while the values it sees are always the live state.
///
/// The seam speaks bonsplit value types (`PaneID`, `ExternalTreeNode`,
/// `LayoutSnapshot`) directly because `CmuxWorkspaces` already depends on
/// `Bonsplit`; the geometry recursions over `ExternalTreeNode` live in
/// `CmuxPanes`. The single mutation
/// (``applySplitDividerPosition(_:forSplit:)``) mirrors the legacy
/// `bonsplitController.setDividerPosition(_:forSplit:fromExternal: true)` write.
@MainActor
public protocol SurfaceLifecycleHosting: AnyObject {
    /// Resolves the bonsplit surface id (`TabID.uuid`) owning the given panel id,
    /// or `nil` when the panel maps to no surface (legacy
    /// `Workspace.surfaceIdFromPanelId`).
    func surfaceId(forPanelId panelId: UUID) -> TabID?

    /// Every pane id, unordered (legacy `bonsplitController.allPaneIds`). Named
    /// distinctly from the `[UUID]`-typed `allPaneIds` that the host already
    /// exposes for `WorkspaceSurfaceTreeReading`, so the two witnesses do not
    /// collide on the concrete `Workspace`.
    var allBonsplitPaneIds: [PaneID] { get }

    /// The pane's tabs in tab order (legacy `bonsplitController.tabs(inPane:)`).
    func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab]

    /// The current split-tree snapshot (legacy
    /// `bonsplitController.treeSnapshot()`).
    func treeSnapshot() -> ExternalTreeNode

    /// The current pixel-coordinate layout snapshot (legacy
    /// `bonsplitController.layoutSnapshot()`).
    func layoutSnapshot() -> LayoutSnapshot

    /// Applies an external divider position to the split with the given id,
    /// returning whether it took (legacy
    /// `bonsplitController.setDividerPosition(_:forSplit:fromExternal: true)`).
    @discardableResult
    func applySplitDividerPosition(_ position: CGFloat, forSplit splitId: UUID) -> Bool
}
