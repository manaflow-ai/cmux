public import Foundation
import Observation

/// Per-window coordinator that owns the *ordering* of a whole-window session
/// snapshot restore, draining the orchestration legacy `TabManager` kept inline
/// in `restoreSessionSnapshot(_:remapClosedPanelHistory:)`.
///
/// The restore is a fixed sequence whose ordering is the behavior being
/// preserved byte-for-byte:
///
/// 1. mark the restore active (so selection side-effects stay suppressed),
/// 2. capture the pre-restore workspaces and reset the per-window sub-model /
///    history state,
/// 3. build the new workspace list **off-publish** (no `@Published` mutation),
/// 4. resolve the new selection and rebuild the workspace groups,
/// 5. **atomically** commit `tabs` / `workspaceGroups` / `selectedTabId` in one
///    assignment so SwiftUI never observes an intermediate empty-`tabs` /
///    `nil`-selection state (the #399 frozen-blank-launch race),
/// 6. prune background loads, release the away workspaces, schedule the initial
///    git metadata, remap closed-panel history, and post `ghosttyDidFocusTab`.
///
/// The coordinator owns this sequence and the pure decisions inside it (the new
/// selection id, the per-group member-id maps, and the stale-group filter set).
/// Every god-coupled step — constructing the `Workspace` objects, the
/// `@Published` assignment, the closed-item-history singleton writes, the
/// sub-model resets — is delegated to the conformer through
/// ``SessionSnapshotRestoreHosting``. The package never imports the
/// `TabManager`/`Workspace` god types.
///
/// **Isolation design.** `@MainActor` because every step reads or mutates live
/// per-window state inside one MainActor restore turn and the host is called
/// synchronously, exactly as the legacy inline body ran; a private actor would
/// reintroduce the suspension windows the atomic-assignment ordering exists to
/// avoid. `@Observable` (not `ObservableObject`) per the refactor migration
/// target, though this stage exposes no observed state. The two snapshot-math
/// collaborators (``SessionSnapshotGroupCoordinator`` for group rebuild,
/// ``ClosedPanelHistoryRemapPlanner`` for the history remap plan) are
/// constructor-injected so they stay a single source of truth shared with the
/// app shell's save-time snapshot path.
@MainActor
@Observable
public final class SessionSnapshotRestoreCoordinator<Tab> where Tab: WorkspaceTabRepresenting {
    @ObservationIgnored
    private weak var host: (any SessionSnapshotRestoreHosting<Tab>)?

    @ObservationIgnored
    private let groupCoordinator: SessionSnapshotGroupCoordinator

    @ObservationIgnored
    private let remapPlanner: ClosedPanelHistoryRemapPlanner

    /// Creates a coordinator with its two snapshot-math collaborators injected
    /// so the same group-rebuild and history-remap logic backs both the restore
    /// path here and the app shell's save-time snapshot path.
    ///
    /// The host is attached separately so the app can construct the coordinator
    /// before the `TabManager` wiring is live, mirroring the other
    /// `CmuxWorkspaces` coordinators.
    public init(
        groupCoordinator: SessionSnapshotGroupCoordinator,
        remapPlanner: ClosedPanelHistoryRemapPlanner
    ) {
        self.groupCoordinator = groupCoordinator
        self.remapPlanner = remapPlanner
    }

    /// Attaches the window-side host. Call before any restore turn.
    public func attach(host: any SessionSnapshotRestoreHosting<Tab>) {
        self.host = host
    }

    /// Sequences a whole-window session snapshot restore.
    ///
    /// Reproduces the legacy `TabManager.restoreSessionSnapshot` ordering exactly;
    /// the only changes are that the god-coupled steps now route through
    /// ``SessionSnapshotRestoreHosting`` and the group/history math through the
    /// injected collaborators. Returns the per-restored-workspace
    /// old-surface-id → new-panel-id maps (legacy
    /// `restoredPanelIdsByWorkspaceIndex`), the value the legacy method returned.
    ///
    /// - Parameters:
    ///   - persistedGroupSnapshots: the snapshot's persisted workspace groups
    ///     (legacy `snapshot.workspaceGroups`), passed through to the group
    ///     coordinator; the app-side snapshot DTO stays owned by the app target.
    ///   - selectedWorkspaceIndex: the snapshot's selected-workspace index
    ///     (legacy `snapshot.selectedWorkspaceIndex`), used to resolve the new
    ///     selection.
    ///   - remapClosedPanelHistory: whether to remap closed-panel history after
    ///     the swap (legacy parameter of the same name; window restore passes
    ///     false and remaps separately).
    ///   - excludingStableIdentities: stable workspace and surface identities
    ///     that must not be re-adopted while replaying the snapshot.
    /// - Returns: the index-aligned old→new panel-id maps for the restored
    ///   workspaces.
    @discardableResult
    public func restore(
        persistedGroupSnapshots: [SessionWorkspaceGroupSnapshot]?,
        selectedWorkspaceIndex: Int?,
        remapClosedPanelHistory: Bool,
        excludingStableIdentities: Set<UUID> = []
    ) -> [[UUID: UUID]] {
        guard let host else { return [] }
        host.beginSessionSnapshotRestore()
        defer { host.endSessionSnapshotRestore() }

        let previousTabs = host.currentWorkspaces()
        host.resetSubModels(previousTabs: previousTabs)

        // Build the new workspace list off-publish to avoid intermediate
        // @Published emissions (empty tabs, nil selectedTabId) that can leave
        // SwiftUI's mountedWorkspaceIds empty and cause a frozen blank launch
        // state (#399).
        let build = host.buildRestoredWorkspaces(excludingStableIdentities: excludingStableIdentities)
        let newTabs = build.tabs

        // Determine selection before mutating @Published properties.
        let newSelectedId: UUID?
        if let selectedWorkspaceIndex,
           newTabs.indices.contains(selectedWorkspaceIndex) {
            newSelectedId = newTabs[selectedWorkspaceIndex].id
        } else {
            newSelectedId = newTabs.first?.id
        }

        // Rebuild the groups from the per-group restored member ids (tab order).
        let workspaceIdsByGroupId = memberIdsByGroupId(in: newTabs)
        let restoredGroups = groupCoordinator.restoreGroups(
            groupSnapshots: persistedGroupSnapshots,
            memberIdsByGroupId: workspaceIdsByGroupId
        )
        let knownGroupIds = Set(restoredGroups.map { $0.id })

        // Single atomic assignment of the @Published properties (with the
        // stale-group cleanup applied first) so SwiftUI observers never see an
        // intermediate state with empty tabs or nil selection.
        host.commitRestoredState(
            tabs: newTabs,
            groups: restoredGroups,
            knownGroupIds: knownGroupIds,
            selectedTabId: newSelectedId
        )

        let existingIds = Set(newTabs.map { $0.id })
        host.pruneBackgroundLoadsAndSelection(existingIds: existingIds)
        host.releaseAwayWorkspaces(previousTabs)
        host.scheduleInitialGitMetadata(for: newTabs)

        if remapClosedPanelHistory {
            let operations = remapPlanner.planSessionRestoreRemaps(
                originalWorkspaceIds: build.restoredOriginalWorkspaceIds,
                restoredWorkspaceIds: newTabs.map { $0.id },
                panelIdMapsByIndex: build.restoredPanelIdsByWorkspaceIndex
            )
            host.applyClosedPanelHistoryRemaps(operations)
        }

        if let newSelectedId {
            host.postDidFocusTab(selectedTabId: newSelectedId)
        }
        return build.restoredPanelIdsByWorkspaceIndex
    }

    /// Builds the per-group ordered restored-member-id map (tab order) the group
    /// coordinator resolves anchors against, reproducing the legacy inline
    /// `workspaceIdsByGroupId` closure.
    private func memberIdsByGroupId(in tabs: [Tab]) -> [UUID: [UUID]] {
        var map: [UUID: [UUID]] = [:]
        for workspace in tabs {
            if let gid = workspace.groupId {
                map[gid, default: []].append(workspace.id)
            }
        }
        return map
    }
}
