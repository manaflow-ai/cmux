public import Foundation
public import Observation

/// The per-workspace surface-list derivation model: turns the live bonsplit
/// split tree and panel registry into the ordered panel-id lists the rest of
/// the app navigates by, and owns the reorder-detection that bumps the
/// workspace's pane-layout version.
///
/// This is the navigation-state half of what the legacy `Workspace` god object
/// computed inline: `orderedPanelIds`, `focusedPanelId`,
/// `representativePanelIdForWorkspaceManualUnread()`,
/// `effectiveSelectedPanelId(inPane:)`, the `tabIdsToLeft/Right/CloseOthers`
/// pane queries, and the `paneLayoutVersion` bump in the geometry-change
/// handler. It owns no stored panel state itself; the registry and the
/// `lastOrderedPanelIds`/`paneLayoutVersion` bookkeeping live in the
/// workspace's `PaneTreeModel`, reached through ``WorkspaceSurfaceTreeReading``.
///
/// The owning `Workspace` composition root holds one instance, attaches itself
/// as the tree-reading host (weak, to avoid a retain cycle), and forwards its
/// legacy accessors here. Every derivation preserves the legacy ordering and
/// fallback chains exactly.
@MainActor
@Observable
public final class WorkspaceSurfaceListModel {
    @ObservationIgnored
    private weak var tree: (any WorkspaceSurfaceTreeReading)?

    /// Creates a detached model; call ``attach(tree:)`` before any derivation.
    public init() {}

    /// Attaches the workspace-side tree-reading seam. Must be called before the
    /// first derivation. Held weakly: the workspace owns this model, so a strong
    /// back-reference would retain-cycle.
    public func attach(tree: any WorkspaceSurfaceTreeReading) {
        self.tree = tree
    }

    /// Panel ids in bonsplit's spatial order: bonsplit tab order across all
    /// panes, deduplicated and filtered to panels that still exist, with any
    /// panels missing from bonsplit appended in stable `uuidString` order so
    /// the list never drops a panel (legacy `Workspace.orderedPanelIds`).
    ///
    /// This is the single source of truth for serializing panels (e.g. the
    /// mobile terminal list) and for detecting reorders.
    public var orderedPanelIds: [UUID] {
        guard let tree else { return [] }
        var result: [UUID] = []
        var seen = Set<UUID>()
        for surfaceId in tree.surfaceIdsInTabOrderAcrossAllPanes {
            guard let panelId = tree.panelId(forSurfaceId: surfaceId), tree.panelExists(panelId) else { continue }
            guard seen.insert(panelId).inserted else { continue }
            result.append(panelId)
        }
        let orphans = tree.allPanelIds
            .filter { !seen.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
        result.append(contentsOf: orphans)
        return result
    }

    /// The focused pane's selected panel id, or `nil` when no pane is focused
    /// or the selection resolves to no panel (legacy
    /// `Workspace.focusedPanelId`).
    public var focusedPanelId: UUID? {
        guard let tree, let surfaceId = tree.focusedPaneSelectedSurfaceId else { return nil }
        return tree.panelId(forSurfaceId: surfaceId)
    }

    /// The panel that owns the workspace-level manual-unread indicator: the
    /// focused panel when it still exists, else the spatially-first selected
    /// panel across panes, else the first sidebar-ordered panel (legacy
    /// `Workspace.representativePanelIdForWorkspaceManualUnread()`).
    public func representativePanelIdForWorkspaceManualUnread() -> UUID? {
        guard let tree else { return nil }
        if let focusedPanelId, tree.panelExists(focusedPanelId) {
            return focusedPanelId
        }

        let selectedPanelsByPaneId = Dictionary(
            uniqueKeysWithValues: tree.allPaneIds.compactMap { paneId -> (UUID, UUID)? in
                guard let surfaceId = tree.selectedSurfaceId(inPaneId: paneId),
                      let panelId = tree.panelId(forSurfaceId: surfaceId),
                      tree.panelExists(panelId) else {
                    return nil
                }
                return (paneId, panelId)
            }
        )

        for paneId in tree.spatiallyOrderedPaneIds {
            guard let panelId = selectedPanelsByPaneId[paneId] else { continue }
            return panelId
        }

        return tree.firstSidebarOrderedPanelId
    }

    /// The selected panel id in the pane, or `nil` when the pane has no
    /// selection or the selection resolves to no panel (legacy
    /// `Workspace.effectiveSelectedPanelId(inPane:)`).
    public func effectiveSelectedPanelId(inPaneId paneId: UUID) -> UUID? {
        guard let tree else { return nil }
        return tree.selectedSurfaceId(inPaneId: paneId).flatMap { tree.panelId(forSurfaceId: $0) }
    }

    /// Surface ids in tab order strictly before the anchor surface in its pane,
    /// or `[]` when the anchor is not in the pane (legacy
    /// `Workspace.tabIdsToLeft(of:inPane:)`).
    public func surfaceIdsToLeft(of anchorSurfaceId: UUID, inPaneId paneId: UUID) -> [UUID] {
        guard let tree else { return [] }
        let surfaceIds = tree.surfaceIdsInTabOrder(inPaneId: paneId)
        guard let index = surfaceIds.firstIndex(of: anchorSurfaceId) else { return [] }
        return Array(surfaceIds.prefix(index))
    }

    /// Surface ids in tab order strictly after the anchor surface in its pane,
    /// or `[]` when the anchor is absent or last (legacy
    /// `Workspace.tabIdsToRight(of:inPane:)`).
    public func surfaceIdsToRight(of anchorSurfaceId: UUID, inPaneId paneId: UUID) -> [UUID] {
        guard let tree else { return [] }
        let surfaceIds = tree.surfaceIdsInTabOrder(inPaneId: paneId)
        guard let index = surfaceIds.firstIndex(of: anchorSurfaceId),
              index + 1 < surfaceIds.count else { return [] }
        return Array(surfaceIds.suffix(from: index + 1))
    }

    /// Every surface id in the pane except the anchor, in tab order (legacy
    /// `Workspace.tabIdsToCloseOthers(of:inPane:)`).
    public func surfaceIdsToCloseOthers(of anchorSurfaceId: UUID, inPaneId paneId: UUID) -> [UUID] {
        guard let tree else { return [] }
        return tree.surfaceIdsInTabOrder(inPaneId: paneId).filter { $0 != anchorSurfaceId }
    }

    /// Reconciles the reorder-detection bookkeeping after a geometry change.
    ///
    /// Every order/membership mutation (same-pane reorder, cross-pane move,
    /// split, close) routes through the workspace's geometry-change handler. A
    /// pure reorder mutates only bonsplit's internal state, which is not
    /// observed, so observers would miss it. This bumps `paneLayoutVersion`
    /// only when the ordered panel-id sequence actually changed, so divider
    /// drags and selection-only events (also routed through that handler) do
    /// not fire an app-wide change (legacy gate in
    /// `Workspace.splitTabBar(_:didChangeGeometry:)`).
    ///
    /// Returns whether the layout version was bumped, for callers that want to
    /// observe the decision in tests.
    @discardableResult
    public func registerGeometryChange() -> Bool {
        guard let tree else { return false }
        let currentOrder = orderedPanelIds
        guard currentOrder != tree.lastOrderedPanelIds else { return false }
        tree.lastOrderedPanelIds = currentOrder
        tree.bumpPaneLayoutVersion()
        return true
    }
}
