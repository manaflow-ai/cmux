public import Foundation

/// The off-publish result of constructing a window's restored workspace list,
/// handed from ``SessionSnapshotRestoreHosting/buildRestoredWorkspaces()`` back
/// to ``SessionSnapshotRestoreCoordinator`` so the coordinator can finish
/// sequencing the restore (selection, group rebuild, atomic assignment, the
/// post-assignment steps) without ever touching the `Workspace` god type or the
/// app-side snapshot DTO.
///
/// **Why the host builds and the coordinator sequences.** Making each
/// `Workspace`, running its per-workspace `restoreSessionSnapshot`, wiring its
/// closed-browser tracking, and allocating its port ordinal are irreducibly
/// app-coupled (they touch the god type and app-static ordinal state), so they
/// stay an app-side witness. But that construction must happen *before* any
/// `@Published` mutation, off-publish, to avoid the #399 blank-launch race where
/// SwiftUI observes an intermediate empty-`tabs`/`nil`-selection state. The host
/// performs the construction into local arrays and returns them here; the
/// coordinator then resolves selection, rebuilds groups, and asks the host to
/// commit all `@Published` properties in one atomic assignment. The ordering —
/// reset, build off-publish, resolve, atomic commit, post-steps — is the
/// behavior the coordinator owns and preserves byte-for-byte.
///
/// The three arrays are index-aligned: element `i` describes the `i`-th restored
/// workspace. The fallback "Terminal 1" workspace the host injects when a
/// snapshot restores zero workspaces is included in ``tabs`` with no matching
/// entry in ``restoredPanelIdsByWorkspaceIndex`` or
/// ``restoredOriginalWorkspaceIds`` (it had no snapshot), exactly as the legacy
/// body left those parallel arrays short for the fallback.
///
/// **Isolation.** `@MainActor`, not `Sendable`: ``tabs`` holds live
/// `@MainActor`-isolated `Workspace` references that never cross an isolation
/// boundary — the host constructs and the coordinator consumes the value inside
/// one MainActor restore turn.
@MainActor
public struct SessionSnapshotRestoreBuild<Tab> where Tab: WorkspaceTabRepresenting {
    /// The freshly constructed workspaces in restore order, including the
    /// injected fallback workspace when the snapshot restored none.
    public let tabs: [Tab]

    /// Per-restored-workspace old-surface-id → new-panel-id maps returned by
    /// each `Workspace.restoreSessionSnapshot`, index-aligned with the
    /// snapshot-backed prefix of ``tabs`` (legacy
    /// `restoredPanelIdsByWorkspaceIndex`).
    public let restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]]

    /// Per-restored-workspace pre-restore workspace id from the snapshot, used to
    /// remap closed-panel history onto the new ids (legacy
    /// `restoredOriginalWorkspaceIds`). `nil` for a snapshot that carried no
    /// workspace id.
    public let restoredOriginalWorkspaceIds: [UUID?]

    /// Creates a build result. The host constructs the three index-aligned
    /// arrays off-publish and hands them to the coordinator.
    public init(
        tabs: [Tab],
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]],
        restoredOriginalWorkspaceIds: [UUID?]
    ) {
        self.tabs = tabs
        self.restoredPanelIdsByWorkspaceIndex = restoredPanelIdsByWorkspaceIndex
        self.restoredOriginalWorkspaceIds = restoredOriginalWorkspaceIds
    }
}
