public import Bonsplit
public import Foundation
import Observation

/// Minimal decoder for a Bonsplit `TabID`'s `Codable` shape, used to recover
/// the inner surface UUID, reproducing the legacy nested `EncodedSurfaceID` the
/// `Workspace.sessionSurfaceUUID(for:)` body declared inline. File-scoped
/// (not nested) because ``SessionRestoreCoordinator`` is generic and a type
/// cannot be nested in a generic method.
private struct EncodedSurfaceID: Decodable {
    let id: UUID
}

/// Per-workspace coordinator owning the persisted-layout serialization bridge
/// that `Workspace` kept inline in its session-snapshot/restore extension.
///
/// This is the first, bounded stage of draining the `Workspace` session
/// snapshot/restore block into `CmuxWorkspaces`. It owns the two cohesive,
/// self-contained halves of the layout wire bridge:
///
/// - ``sessionLayoutSnapshot(from:)`` — reads the live Bonsplit
///   `ExternalTreeNode` and the host's surface-id → panel-id map to build the
///   persisted layout DTO (the app type, minted through
///   ``SessionLayoutNodeBuilding``).
/// - ``applySessionDividerPositions(snapshotNode:liveNode:)`` — walks a restored
///   layout DTO and the live tree in lockstep, re-applying each split's divider
///   position through ``WorkspaceSessionRestoreHosting``.
///
/// The richer snapshot/restore orchestration (`sessionSnapshot`,
/// `restoreSessionSnapshot`, `sessionPanelSnapshot`, `createPanel`,
/// `restorePane`, the closed-panel history, notifications) stays an app-target
/// shim for now: those bodies reach ~55 `Workspace`/`AppDelegate`/`TerminalController`
/// surface-creation and notification methods that are not yet extracted, so a
/// faithful lift of them would require a god-sized host seam. They migrate in a
/// later stage as their substrate (surface creation, pane/split lifecycle)
/// drains; this coordinator is the home they migrate into.
///
/// **Isolation design.** `@MainActor` because every entry point is a MainActor
/// session snapshot/restore turn that reads the host's live pane-tree state and
/// issues synchronous Bonsplit divider mutations. The host is called
/// synchronously inside one turn, preserving the legacy interleavings exactly.
/// `@Observable` (not `ObservableObject`) per the refactor migration target,
/// though this stage exposes no observed state yet.
///
/// **Layout DTO genericity.** The coordinator is generic over the app's
/// persisted layout enum, constrained to ``SessionLayoutPruning`` (structural
/// read) and ``SessionLayoutNodeBuilding`` (structural build), so the wire
/// format and the concrete pane/split `Codable` DTOs stay owned by the app
/// target. The package reads the live tree, decides the shape, and asks the
/// conformer to mint the matching nodes — the same boundary ``SessionLayoutPruning``
/// already established for pruning.
///
/// Bodies are lifted one-for-one from the `Workspace` extension in
/// `Sources/Workspace.swift`; only the host-seam spellings and the
/// node-construction hand-off changed.
@MainActor
@Observable
public final class SessionRestoreCoordinator<Layout> where Layout: SessionLayoutPruning & SessionLayoutNodeBuilding {
    @ObservationIgnored
    private weak var host: (any WorkspaceSessionRestoreHosting)?

    /// Creates a coordinator. The host is attached separately so the workspace
    /// can construct the coordinator before the pane-tree/controller wiring is
    /// live, mirroring the other `CmuxWorkspaces` coordinators.
    public init() {}

    /// Attaches the window-side host. Call before any snapshot/restore turn.
    public func attach(host: any WorkspaceSessionRestoreHosting) {
        self.host = host
    }

    // MARK: - Snapshot (live tree → persisted layout DTO)

    /// Builds the persisted layout DTO for a live Bonsplit tree, reproducing
    /// the legacy `Workspace.sessionLayoutSnapshot(from:)`.
    public func sessionLayoutSnapshot(from node: ExternalTreeNode) -> Layout {
        switch node {
        case .pane(let pane):
            let panelIds = sessionPanelIDs(for: pane)
            let selectedPanelId = pane.selectedTabId.flatMap(sessionPanelID(forExternalTabIDString:))
            let isFullWidthTabMode = UUID(uuidString: pane.id).map { paneId in
                host?.sessionFullWidthTabMode(forPaneId: paneId) ?? false
            }
            return Layout.sessionLayoutBuiltPane(
                panelIds: panelIds,
                selectedPanelId: selectedPanelId,
                isFullWidthTabMode: isFullWidthTabMode
            )
        case .split(let split):
            return Layout.sessionLayoutBuiltSplit(
                isVertical: split.orientation.lowercased() == "vertical",
                dividerPosition: split.dividerPosition,
                first: sessionLayoutSnapshot(from: split.first),
                second: sessionLayoutSnapshot(from: split.second)
            )
        }
    }

    /// The ordered, de-duplicated panel ids hosted by a live pane, reproducing
    /// the legacy `Workspace.sessionPanelIDs(for:)`.
    private func sessionPanelIDs(for pane: ExternalPaneNode) -> [UUID] {
        var panelIds: [UUID] = []
        var seen = Set<UUID>()
        for tab in pane.tabs {
            guard let panelId = sessionPanelID(forExternalTabIDString: tab.id) else { continue }
            if seen.insert(panelId).inserted {
                panelIds.append(panelId)
            }
        }
        return panelIds
    }

    /// Resolves a Bonsplit tab-id string to its owning panel id by matching the
    /// decoded surface UUID against the host's surface-id map, reproducing the
    /// legacy `Workspace.sessionPanelID(forExternalTabIDString:)`.
    private func sessionPanelID(forExternalTabIDString tabIDString: String) -> UUID? {
        guard let tabUUID = UUID(uuidString: tabIDString) else { return nil }
        guard let host else { return nil }
        for (surfaceId, panelId) in host.surfaceIdToPanelId {
            guard let surfaceUUID = sessionSurfaceUUID(for: surfaceId) else { continue }
            if surfaceUUID == tabUUID {
                return panelId
            }
        }
        return nil
    }

    /// Decodes a Bonsplit `TabID`'s inner surface UUID through its `Codable`
    /// shape, reproducing the legacy `Workspace.sessionSurfaceUUID(for:)`.
    private func sessionSurfaceUUID(for surfaceId: TabID) -> UUID? {
        guard let data = try? JSONEncoder().encode(surfaceId),
              let decoded = try? JSONDecoder().decode(EncodedSurfaceID.self, from: data) else {
            return nil
        }
        return decoded.id
    }

    // MARK: - Restore (persisted layout DTO → live divider positions)

    /// Re-applies a restored layout's divider positions to the live tree,
    /// walking both in lockstep, reproducing the legacy
    /// `Workspace.applySessionDividerPositions(snapshotNode:liveNode:)`.
    public func applySessionDividerPositions(
        snapshotNode: Layout,
        liveNode: ExternalTreeNode
    ) {
        switch (snapshotNode.sessionLayoutPruneCase, liveNode) {
        case let (.split(snapshotDividerPosition, snapshotFirst, snapshotSecond), .split(liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                host?.applySessionDividerPosition(
                    CGFloat(snapshotDividerPosition),
                    forSplit: splitID
                )
            }
            applySessionDividerPositions(snapshotNode: snapshotFirst, liveNode: liveSplit.first)
            applySessionDividerPositions(snapshotNode: snapshotSecond, liveNode: liveSplit.second)
        default:
            return
        }
    }

    // MARK: - Surface resume bindings (stored ↔ process-detected resolution)

    /// Decides how to reconcile one panel's stored resume binding against the
    /// freshly detected one, byte-faithfully reproducing the per-panel branches
    /// of the legacy `Workspace.reconcileSurfaceResumeBindings(using:)` loop.
    ///
    /// The host iterates its live panels and applies each returned action to its
    /// own `[UUID: Binding]` map, so the decision logic lives here while the
    /// live-state read/mutation stays app-side (the map and the panel set are
    /// `Workspace`-owned live state). `stored` is the panel's current map value
    /// (may be `nil`); `detected` is the resume index's binding for the panel
    /// (may be `nil`).
    public func reconcileResumeBinding<Binding>(
        stored: Binding?,
        detected: Binding?
    ) -> SurfaceResumeBindingReconcileAction<Binding>
    where Binding: SurfaceResumeBindingResolving & Sendable {
        guard let stored else {
            if let detected, detected.isProcessDetected {
                return .store(detected)
            }
            return .keep
        }
        guard let detected else {
            if stored.isProcessDetected {
                return .remove
            }
            return .keep
        }
        if stored.shouldYieldToDetectedSurfaceResumeBinding(detected) {
            return .store(detected)
        } else if stored.isProcessDetected {
            return .remove
        }
        return .keep
    }

    /// Resolves the effective resume binding for one panel from its `stored`
    /// binding and the `detected` binding from the resume index, byte-faithfully
    /// reproducing the legacy
    /// `Workspace.effectiveSurfaceResumeBinding(panelId:surfaceResumeBindingIndex:)`.
    ///
    /// When the caller has no resume index it passes `hasDetectionSource: false`
    /// and the stored binding is returned verbatim, matching the legacy early
    /// return for a `nil` index (which preserved a process-detected stored
    /// binding, unlike the present-index path that drops it when no detection
    /// exists).
    public func effectiveResumeBinding<Binding>(
        stored: Binding?,
        detected: Binding?,
        hasDetectionSource: Bool
    ) -> Binding?
    where Binding: SurfaceResumeBindingResolving & Sendable {
        guard hasDetectionSource else {
            return stored
        }
        guard let stored else { return detected }
        guard let detected else { return stored.isProcessDetected ? nil : stored }
        if stored.shouldYieldToDetectedSurfaceResumeBinding(detected) { return detected }
        if stored.isProcessDetected { return nil }
        return stored
    }

    // MARK: - Closed-panel restore anchoring

    /// Chooses which sibling tab a closing panel should anchor its restore to,
    /// byte-faithfully reproducing the inline neighbor-selection branch of the
    /// legacy `Workspace.closedPanelHistoryEntry(panelId:tabId:pane:)` body.
    ///
    /// The legacy body, having located the closing tab at `closedTabIndex` in a
    /// pane holding `tabCount` tabs, preferred the tab immediately *after* the
    /// closing one, fell back to the tab immediately *before* it, and produced no
    /// anchor when the closing tab was the pane's only tab. Returning the chosen
    /// index (rather than a resolved panel id) keeps the live tab-list read and
    /// the `surfaceId → panelId` resolution app-side, where the pane-tree state
    /// lives, while the selection rule lives here with the other restore
    /// decisions. The caller resolves `paneTabs[index].id` through its own map.
    ///
    /// Returns `nil` when there is no sibling to anchor to (the closing tab is
    /// the pane's only tab, or `closedTabIndex` is out of range), exactly as the
    /// legacy `return nil` fall-through did.
    public func paneAnchorNeighborIndex(forClosedTabIndex closedTabIndex: Int, tabCount: Int) -> Int? {
        if closedTabIndex + 1 < tabCount {
            return closedTabIndex + 1
        }
        if closedTabIndex > 0 {
            return closedTabIndex - 1
        }
        return nil
    }

    // MARK: - Persisted panel ordering

    /// Builds the ordered, de-duplicated, capped list of panel ids a workspace
    /// snapshot persists, byte-faithfully reproducing the inline merge at the top
    /// of the legacy `Workspace.sessionSnapshot(includeScrollback:...)` body.
    ///
    /// The legacy body merged two sources in order: first the sidebar's display
    /// order (`sidebarOrderedPanelIds()`), then every remaining live panel id
    /// sorted by `uuidString`, de-duplicating with a single `Set` as it walked
    /// both lists, then took `.prefix(maxPanelsPerWorkspace)` before mapping each
    /// surviving id to a panel snapshot. The two source lists and the live panel
    /// set are `Workspace`-owned live state, so the host gathers them (it already
    /// sorts the remaining ids while reading `panels.keys`); the ordering, the
    /// first-source-wins de-duplication, and the cap live here with the other
    /// snapshot decisions. The caller maps each returned id to its snapshot,
    /// exactly as the legacy `compactMap` did.
    ///
    /// - Parameters:
    ///   - sidebarOrdered: the sidebar display order (legacy
    ///     `sidebarOrderedPanelIds()`), consulted first.
    ///   - remaining: every other live panel id, already in the legacy
    ///     `uuidString`-sorted order (legacy `panels.keys.sorted(by:)`),
    ///     consulted second; ids already seen in `sidebarOrdered` are dropped.
    ///   - limit: the maximum number of panels a workspace persists (legacy
    ///     `SessionPersistencePolicy.maxPanelsPerWorkspace`), kept app-side so the
    ///     wire/persistence constant stays owned by the app target.
    /// - Returns: the merged, de-duplicated ids truncated to `limit`, in the
    ///   exact order the legacy `allPanelIds.prefix(limit)` produced.
    public func persistedPanelIdOrder(
        sidebarOrdered: [UUID],
        remaining: [UUID],
        limit: Int
    ) -> [UUID] {
        var seen: Set<UUID> = []
        var allPanelIds: [UUID] = []
        for panelId in sidebarOrdered where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        for panelId in remaining where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        return Array(allPanelIds.prefix(limit))
    }
}
