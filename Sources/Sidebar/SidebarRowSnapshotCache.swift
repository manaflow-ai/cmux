import Foundation
import Observation

/// The one snapshot owner shared by the native and legacy workspace sidebars.
/// Material event batches publish only a revision, avoiding copy-on-write copies
/// of the entire snapshot dictionary and retention of retired workspaces.
@MainActor
@Observable
final class SidebarRowSnapshotCache {
    @ObservationIgnored private(set) var snapshotsById: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
    private(set) var revision: UInt64 = 0

    deinit {}

    func value(for id: UUID) -> SidebarWorkspaceSnapshotBuilder.Snapshot? {
        _ = revision
        return snapshotsById[id]
    }

    /// Reconciles membership and settings from lifecycle events, outside rendering.
    /// Reusing valid snapshots keeps membership changes scoped to new workspaces.
    func reconcile(
        workspaceIds: Set<UUID>,
        presentationKey: SidebarWorkspaceSnapshotBuilder.PresentationKey,
        snapshot: (UUID) -> SidebarWorkspaceSnapshotBuilder.Snapshot?
    ) {
        var next: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
        next.reserveCapacity(workspaceIds.count)
        for id in workspaceIds {
            if let cached = snapshotsById[id], cached.presentationKey == presentationKey {
                next[id] = cached
            } else {
                next[id] = snapshot(id)
            }
        }
        replace(with: next)
    }

    /// Deactivation already removes the parent; cleanup publishes nothing.
    func prune(keeping ids: Set<UUID>) {
        for id in snapshotsById.keys where !ids.contains(id) {
            snapshotsById.removeValue(forKey: id)
        }
    }

    func refresh(
        workspaceIds: Set<UUID>,
        snapshot: (UUID) -> SidebarWorkspaceSnapshotBuilder.Snapshot?
    ) {
        var changed = false
        for id in workspaceIds {
            let next = snapshot(id)
            guard snapshotsById[id] != next else { continue }
            snapshotsById[id] = next
            changed = true
        }
        if changed { revision &+= 1 }
    }

    func replace(with snapshots: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot]) {
        guard snapshotsById != snapshots else { return }
        snapshotsById = snapshots
        revision &+= 1
    }
}
