public import Foundation

/// The workspace-side seam the surface-list model reads through to derive its
/// ordered panel lists and reorder-detection state.
///
/// **Why a synchronous read-only protocol and not value snapshots.** Every
/// derivation (`orderedPanelIds`, `focusedPanelId`,
/// `representativePanelId(forWorkspaceManualUnread:)`, the reorder bump) is one
/// MainActor turn that must observe the live `BonsplitController` split tree and
/// the live panel registry exactly as the legacy computed properties on
/// `Workspace` did. The split tree, pane selection, and tab order are owned by
/// `BonsplitController`; the panel registry, `lastOrderedPanelIds`, and
/// `paneLayoutVersion` are owned by the workspace's `PaneTreeModel`. The model
/// reads them through this seam so it never imports `Bonsplit` and stays a pure
/// leaf, while the values it sees are always the authoritative current state.
///
/// All identifiers are surfaced as `UUID`/`UUID` arrays: bonsplit `TabID`/
/// `PaneID` are 1:1 with `UUID`, so the seam erases the opaque bonsplit types at
/// the boundary. Reads return `nil`/`[]` when a pane or surface is gone,
/// mirroring the legacy optional-chained lookups.
@MainActor
public protocol WorkspaceSurfaceTreeReading: AnyObject {
    // MARK: Bonsplit tree reads

    /// Every surface (bonsplit `TabID.uuid`) across all panes in bonsplit's tab
    /// order (legacy `bonsplitController.allTabIds`). Pane grouping is not
    /// preserved here; this is the flat membership sequence used by
    /// ``WorkspaceSurfaceListModel/orderedPanelIds``.
    var surfaceIdsInTabOrderAcrossAllPanes: [UUID] { get }

    /// The surface id of the selected tab in the currently focused pane, or
    /// `nil` when no pane is focused or the focused pane has no selection
    /// (legacy `bonsplitController.selectedTab(inPane: focusedPaneId)?.id`).
    var focusedPaneSelectedSurfaceId: UUID? { get }

    /// Every pane id (bonsplit `PaneID.id`), unordered (legacy
    /// `bonsplitController.allPaneIds`).
    var allPaneIds: [UUID] { get }

    /// Pane ids in on-screen spatial order (depth-first over the split tree),
    /// the legacy `bonsplitController.treeSnapshot().orderedPaneIds` mapped to
    /// `UUID`. Used to resolve the representative panel deterministically.
    var spatiallyOrderedPaneIds: [UUID] { get }

    /// The selected tab's surface id in the pane, or `nil` when the pane has no
    /// selection (legacy `bonsplitController.selectedTab(inPane:)?.id`).
    func selectedSurfaceId(inPaneId paneId: UUID) -> UUID?

    /// The pane's surface ids in tab order (legacy
    /// `bonsplitController.tabs(inPane:)` mapped to `\.id`).
    func surfaceIdsInTabOrder(inPaneId paneId: UUID) -> [UUID]

    // MARK: Panel-registry reads

    /// Resolves the owning panel id for a surface id, or `nil` when the surface
    /// maps to no panel (legacy `Workspace.panelIdFromSurfaceId`).
    func panelId(forSurfaceId surfaceId: UUID) -> UUID?

    /// Whether a panel id currently exists in the workspace panel registry
    /// (legacy `panels[panelId] != nil`).
    func panelExists(_ panelId: UUID) -> Bool

    /// All panel ids in the workspace registry, unordered (legacy
    /// `panels.keys`). The model sorts these by `uuidString` for the stable
    /// orphan/fallback tail, matching the legacy ordering.
    var allPanelIds: [UUID] { get }

    /// The first ordered panel id from the sidebar ordering, used only as the
    /// last-resort representative fallback (legacy
    /// `sidebarOrderedPanelIds().first`). Sidebar ordering depends on
    /// directory/branch resolution owned by the workspace, so it stays
    /// host-side.
    var firstSidebarOrderedPanelId: UUID? { get }

    // MARK: Reorder bookkeeping (PaneTreeModel-owned)

    /// The spatially ordered panel ids captured at the last geometry
    /// notification, used to gate reorder bumps (legacy
    /// `Workspace.lastOrderedPanelIds`, owned by `PaneTreeModel`).
    var lastOrderedPanelIds: [UUID] { get set }

    /// Bumps the monotonic pane-layout version (legacy
    /// `Workspace.paneLayoutVersion &+= 1`, owned by `PaneTreeModel`). Wrapping
    /// add, matching the legacy `&+=`.
    func bumpPaneLayoutVersion()
}
