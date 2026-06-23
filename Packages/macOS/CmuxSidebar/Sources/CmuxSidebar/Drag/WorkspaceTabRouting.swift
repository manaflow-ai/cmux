public import Foundation
public import CmuxFoundation

/// The reorder/move routing seam the sidebar's tab drop delegates operate
/// through.
///
/// The sidebar's drag/drop machinery needs to read this window's workspace
/// ordering, query group membership and pin tiers, reorder a workspace within
/// the window, and move a workspace in from another window. All of that lives
/// on the app target's `TabManager` (per-window order/groups/selection) and
/// `AppDelegate` (cross-window window/manager resolution and the actual
/// cross-window move). This protocol is the single seam those operations cross
/// the module boundary through, so the drop delegates carry no reference to a
/// god object and reason only in value types (`UUID`, `Set<UUID>`,
/// `ClosedRange<Int>`, ``SidebarDropPlanner`` inputs).
///
/// `@MainActor` because every operation reads or mutates per-window workspace
/// state that is main-actor owned and driven synchronously from the SwiftUI
/// `DropDelegate` callbacks (which run on the main actor). Co-locating the seam
/// with its callers keeps the drop path a sequence of plain main-actor calls
/// with no bridging.
///
/// The app target supplies the single conformer at the composition root, wiring
/// each requirement to the matching `TabManager`/`AppDelegate` method so the
/// behavior is byte-identical to the legacy inline drop-delegate code.
@MainActor
public protocol WorkspaceTabRouting: AnyObject {
    // MARK: Local window reads

    /// This window's workspace ids in sidebar order (legacy `tabManager.tabs.map(\.id)`).
    var localWorkspaceIds: [UUID] { get }

    /// This window's currently focused/selected workspace id
    /// (legacy `tabManager.selectedTabId`).
    var selectedWorkspaceId: UUID? { get }

    /// This window's multi-selection (legacy `tabManager.sidebarSelectedWorkspaceIds`).
    var selectedWorkspaceIds: Set<UUID> { get }

    /// Whether `workspaceId` is one of this window's workspaces
    /// (legacy `tabManager.tabs.contains { $0.id == workspaceId }`).
    func containsLocalWorkspace(_ workspaceId: UUID) -> Bool

    /// Whether `workspaceId` is a group *anchor* in this window
    /// (legacy `tabManager.workspaceGroups.contains { $0.anchorWorkspaceId == workspaceId }`).
    func isLocalGroupAnchor(_ workspaceId: UUID) -> Bool

    /// Whether this window has any workspace groups
    /// (legacy `!tabManager.workspaceGroups.isEmpty`).
    var hasLocalWorkspaceGroups: Bool { get }

    /// The group anchor a hovered destination row resolves to: a group member
    /// resolves to its group's anchor, since an incoming ungrouped workspace
    /// lands at the group boundary. Returns `workspaceId` itself when it is not
    /// a group member (legacy `crossWindowTopLevelTarget()` body).
    func topLevelGroupAnchor(forWorkspace workspaceId: UUID) -> UUID?

    // MARK: Reorder planner inputs

    /// Whether reorder reasoning for this drag/target pair operates in
    /// top-level (group-folded) row space
    /// (legacy `tabManager.sidebarReorderUsesTopLevelRows(...)`).
    func sidebarReorderUsesTopLevelRows(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        workspaceGroupIdByWorkspaceId: [UUID: UUID?]
    ) -> Bool

    /// The workspace ids the reorder operates over, in the requested row space
    /// (legacy `tabManager.sidebarReorderWorkspaceIds(...)`).
    func sidebarReorderWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> [UUID]

    /// The pinned subset of the reorder ids in the requested row space
    /// (legacy `tabManager.sidebarReorderPinnedWorkspaceIds(...)`).
    func sidebarReorderPinnedWorkspaceIds(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> Set<UUID>

    /// The legal insertion range for the dragged workspace given the target
    /// (legacy `tabManager.sidebarReorderLegalInsertionRange(...)`).
    func sidebarReorderLegalInsertionRange(
        forDraggedWorkspaceId draggedWorkspaceId: UUID?,
        targetWorkspaceId: UUID?,
        usesTopLevelRows: Bool
    ) -> ClosedRange<Int>?

    // MARK: Mutations

    /// Reorders `workspaceId` to `index` within this window, returning whether
    /// anything changed (legacy `tabManager.reorderSidebarWorkspace(...)`).
    @discardableResult
    func reorderSidebarWorkspace(
        workspaceId: UUID,
        toIndex index: Int,
        isDragOperation: Bool,
        usesTopLevelRows: Bool
    ) -> Bool

    // MARK: Cross-window move

    /// Whether `workspaceId` lives in a *different* window than this one and is
    /// not a group anchor there, i.e. it can be dropped into this window. The
    /// conformer resolves the source window via `AppDelegate.tabManagerFor(tabId:)`
    /// and rejects source group anchors (moving only the anchor would dissolve
    /// the source group). Combines the legacy `isCrossWindowGroupAnchorDrag`
    /// guard into one routing decision.
    func isCrossWindowGroupAnchor(_ workspaceId: UUID) -> Bool

    /// The foreign dragged workspace's pin state, resolved once when a foreign
    /// drag is mirrored into this window (legacy
    /// `AppDelegate.shared?.tabManagerFor(tabId:)?.tabs.first{...}?.isPinned`).
    func foreignWorkspaceIsPinned(_ workspaceId: UUID) -> Bool

    /// Plans and commits a cross-window move of `draggedWorkspaceId` (and its
    /// source-window multi-selection, when it is part of one) into this window,
    /// honoring the drop indicator. Returns the moved workspace ids in landing
    /// order, or an empty array when nothing moved. Encapsulates the entire
    /// legacy `performCrossWindowDrop` body (source-selection expansion, per
    /// pin-tier base-slot planning via ``SidebarDropPlanner``, the focus move),
    /// since every step reaches `AppDelegate`/source-`TabManager` state that
    /// cannot cross the module boundary.
    @discardableResult
    func performCrossWindowDrop(
        draggedWorkspaceId: UUID,
        targetTopLevelWorkspaceId: UUID?,
        indicator: SidebarDropIndicator?
    ) -> [UUID]

    // MARK: Bonsplit tab move

    /// The bonsplit tab id of the drag currently on the `.drag` pasteboard that
    /// originated in *this* process, or `nil` when there is no current-process
    /// bonsplit transfer. Encapsulates the legacy `BonsplitTabDragPayload`
    /// pasteboard decode (which lives app-side because the payload type is shared
    /// by the bonsplit move overlays); the moved bonsplit drop delegate keys on
    /// the resolved id and never touches the pasteboard or the payload type.
    func currentBonsplitDraggedTabId() -> UUID?

    /// The workspace id that already owns the bonsplit surface `tabId`, or `nil`
    /// when no surface is found (legacy
    /// `AppDelegate.shared?.locateBonsplitSurface(tabId:)?.workspaceId`).
    func bonsplitSurfaceOwningWorkspaceId(forTabId tabId: UUID) -> UUID?

    /// Moves the bonsplit `tabId` into `targetWorkspaceId`, focusing it, and
    /// returns whether the move succeeded (legacy
    /// `AppDelegate.shared?.moveBonsplitTab(...)`).
    func moveBonsplitTab(tabId: UUID, toWorkspace targetWorkspaceId: UUID) -> Bool
}
