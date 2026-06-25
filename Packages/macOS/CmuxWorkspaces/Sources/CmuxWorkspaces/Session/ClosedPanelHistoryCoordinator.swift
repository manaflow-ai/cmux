public import Foundation
public import Bonsplit
import CmuxPanes

/// Owns a workspace's recently-closed-panel decisions: whether a closing tab is
/// eligible to be remembered, how to capture it into a ``ClosedPanelHistoryEntry``
/// (which pane neighbor it anchors to, which fallback split recreates its pane),
/// and where a remembered panel reopens (original pane, anchor pane, fallback
/// split, or the focused pane).
///
/// Lifted one-for-one from the legacy `Workspace` closed-panel cluster
/// (`closedPanelHistoryEntry`, `consumeCloseHistoryEligibility`,
/// `clearCloseHistoryEligibility`, `pushClosedPanelHistoryIfEligible`,
/// `restoreClosedPanel(_:)`, `restoreClosedPanel(_:inPane:)`,
/// `restoreClosedPanelInFallbackSplit`). It is generic over the captured panel
/// `Snapshot` because that DTO (`SessionPanelSnapshot`) is owned by the executable
/// target; the app instantiates it as
/// `ClosedPanelHistoryCoordinator<SessionPanelSnapshot>`. Every live read/write
/// goes through ``WorkspaceClosedPanelHistoryHosting`` so this type never holds the
/// app-target `Workspace`; the panel/snapshot creation that those bodies performed
/// inline stays app-side behind the seam. The neighbor-selection rule itself still lives
/// in ``SessionRestoreCoordinator/paneAnchorNeighborIndex(forClosedTabIndex:tabCount:)``,
/// invoked through the host so it is single-sourced.
@MainActor
public final class ClosedPanelHistoryCoordinator<Snapshot> where Snapshot: Codable & Sendable {
    private weak var host: (any WorkspaceClosedPanelHistoryHosting<Snapshot>)?

    /// Creates the coordinator. Call ``attach(host:)`` before use.
    public init() {}

    /// Attaches the workspace-side host the decisions read and drive through.
    public func attach(host: any WorkspaceClosedPanelHistoryHosting<Snapshot>) {
        self.host = host
    }

    // MARK: - Eligibility

    /// Consumes the close-history eligibility for a closing surface/panel,
    /// returning whether either key was eligible (legacy
    /// `Workspace.consumeCloseHistoryEligibility(tabId:panelId:)`).
    public func consumeCloseHistoryEligibility(tabId: TabID, panelId: UUID?) -> Bool {
        host?.surfaceRegistryConsumeCloseHistoryEligibility(tabId: tabId, panelId: panelId) ?? false
    }

    /// Clears the close-history eligibility for a surface and its resolved owning
    /// panel without recording history (legacy
    /// `Workspace.clearCloseHistoryEligibility(tabId:panelId:)`). When `panelId`
    /// is omitted the host resolves the owning panel from the surface id, exactly
    /// as the legacy default-argument body did.
    public func clearCloseHistoryEligibility(tabId: TabID, panelId: UUID? = nil) {
        guard let host else { return }
        host.surfaceRegistryClearCloseHistoryEligibility(
            tabId: tabId,
            panelId: panelId ?? host.panelIdFromSurfaceId(tabId)
        )
    }

    // MARK: - Capture

    /// Captures the closing panel into a ``ClosedPanelHistoryEntry``, or `nil`
    /// when history is suppressed, the closing tab is not in the pane, or no
    /// snapshot can be built. Faithful lift of
    /// `Workspace.closedPanelHistoryEntry(panelId:tabId:pane:)`: the
    /// neighbor-anchor selection, browser-close fallback split plan, and snapshot
    /// build all run through the host against live state.
    public func closedPanelHistoryEntry(
        panelId: UUID,
        tabId: TabID,
        pane: PaneID
    ) -> ClosedPanelHistoryEntry<Snapshot>? {
        guard let host, !host.suppressClosedPanelHistory else { return nil }
        let paneTabs = host.tabs(inPane: pane)
        guard let tabIndex = paneTabs.firstIndex(where: { $0.id == tabId }) else {
            return nil
        }
        // The neighbor-selection rule lives in SessionRestoreCoordinator; the host
        // applies it and resolves the chosen tab's surface id to its panel id
        // against the live pane-tree state.
        let paneAnchorPanelId = host.closedPanelAnchorPanelId(
            forClosedTabIndex: tabIndex,
            inPane: pane
        )
        let fallbackPlan = host.closedPanelHistoryTreeSnapshot().browserCloseFallbackPlan(
            forPaneId: pane.id.uuidString
        )
        let fallbackAnchorPanelId = fallbackPlan?.anchorPaneId.flatMap { anchorPaneId -> UUID? in
            guard let anchorPane = host.allBonsplitPaneIds.first(where: { $0.id == anchorPaneId }),
                  let anchorTab = host.selectedOrFirstTab(inPane: anchorPane) else {
                return nil
            }
            return host.panelIdFromSurfaceId(anchorTab.id)
        }
        let fallbackSplitPlacement = fallbackPlan.map {
            ClosedPanelSplitPlacement(
                orientation: $0.orientation,
                insertFirst: $0.insertFirst,
                anchorPanelId: fallbackAnchorPanelId
            )
        }
        guard let snapshot = host.buildClosedPanelSnapshot(panelId: panelId) else {
            return nil
        }
        return ClosedPanelHistoryEntry(
            workspaceId: host.closedPanelHistoryWorkspaceId,
            paneId: pane.id,
            paneAnchorPanelId: paneAnchorPanelId,
            tabIndex: tabIndex,
            snapshot: snapshot,
            fallbackSplitPlacement: fallbackSplitPlacement
        )
    }

    /// Pushes the closing tab onto the recently-closed history stack when it is
    /// eligible, returning whether anything was pushed. Faithful lift of
    /// `Workspace.pushClosedPanelHistoryIfEligible(for:inPane:)`.
    @discardableResult
    public func pushClosedPanelHistoryIfEligible(for tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        guard let host, !host.suppressClosedPanelHistory else { return false }
        guard let panelId = host.panelIdFromSurfaceId(tab.id) else { return false }
        guard host.surfaceRegistryConsumeCloseHistoryEligibility(tabId: tab.id, panelId: panelId) else { return false }
        guard let entry = closedPanelHistoryEntry(panelId: panelId, tabId: tab.id, pane: pane) else {
            return false
        }
        host.pushClosedPanelHistory(entry)
        return true
    }

    // MARK: - Restore

    /// Reopens a remembered panel, routing through the original pane, then the
    /// anchor pane, then the fallback split, then the focused pane, and returns
    /// the restored panel id. Faithful lift of
    /// `Workspace.restoreClosedPanel(_:)`.
    @discardableResult
    public func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry<Snapshot>) -> UUID? {
        guard let host else { return nil }
        if entry.restoreInOriginalPane,
           let originalPane = host.allBonsplitPaneIds.first(where: { $0.id == entry.paneId }) {
            return restoreClosedPanel(entry, inPane: originalPane)
        }
        if let paneAnchorPanelId = entry.paneAnchorPanelId,
           let pane = host.paneId(forPanelId: paneAnchorPanelId) {
            return restoreClosedPanel(entry, inPane: pane)
        }
        if let splitPanelId = restoreClosedPanelInFallbackSplit(entry) {
            host.triggerFocusFlash(panelId: splitPanelId)
            return splitPanelId
        }
        guard let pane = host.focusedOrFirstPaneId else {
            return nil
        }
        return restoreClosedPanel(entry, inPane: pane)
    }

    /// Reopens a remembered panel into a specific pane at its captured tab index,
    /// then focuses and flashes it. Faithful lift of the private
    /// `Workspace.restoreClosedPanel(_:inPane:)`.
    @discardableResult
    private func restoreClosedPanel(_ entry: ClosedPanelHistoryEntry<Snapshot>, inPane pane: PaneID) -> UUID? {
        guard let host,
              let panelId = host.createPanel(from: entry.snapshot, inPane: pane) else {
            return nil
        }
        let maxIndex = max(0, host.tabs(inPane: pane).count - 1)
        host.reorderSurface(panelId: panelId, toIndex: min(max(entry.tabIndex, 0), maxIndex))
        host.focusPaneSelectingPanel(pane, panelId: panelId)
        host.focusPanel(panelId)
        host.triggerFocusFlash(panelId: panelId)
        return panelId
    }

    /// Recreates the pane the panel lived in beside a surviving anchor, restores
    /// the panel into it, retires the placeholder, and focuses the result.
    /// Faithful lift of the private
    /// `Workspace.restoreClosedPanelInFallbackSplit(_:)`.
    @discardableResult
    private func restoreClosedPanelInFallbackSplit(_ entry: ClosedPanelHistoryEntry<Snapshot>) -> UUID? {
        guard let host,
              let placement = entry.fallbackSplitPlacement,
              let anchorPanelId = placement.anchorPanelId,
              host.hasLivePanel(id: anchorPanelId) else {
            return nil
        }
        guard let placeholderPanelId = host.newFallbackTerminalSplit(
            fromPanelId: anchorPanelId,
            orientation: placement.orientation,
            insertFirst: placement.insertFirst
        ) else {
            return nil
        }
        guard let pane = host.paneId(forPanelId: placeholderPanelId) else {
            host.closePanel(placeholderPanelId)
            return nil
        }
        guard let panelId = host.createPanel(from: entry.snapshot, inPane: pane) else {
            host.closePanel(placeholderPanelId)
            return nil
        }
        host.closePanel(placeholderPanelId)
        guard host.hasLivePanel(id: panelId) else {
            return nil
        }
        host.focusPanel(panelId)
        return panelId
    }
}
