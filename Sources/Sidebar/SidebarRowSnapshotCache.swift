import Foundation
import Observation

/// The one snapshot owner shared by the native and legacy workspace sidebars.
/// Material event batches publish only a revision, avoiding copy-on-write copies
/// of the entire snapshot dictionary and retention of retired workspaces.
@MainActor
@Observable
final class SidebarRowSnapshotCache {
    @ObservationIgnored private(set) var snapshotsById: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
    @ObservationIgnored private var settingsFingerprint: SidebarTabItemSettingsSnapshot?
    private(set) var revision: UInt64 = 0

    func resetIfSettingsChanged(_ settings: SidebarTabItemSettingsSnapshot) {
        guard settingsFingerprint != settings else { return }
        settingsFingerprint = settings
        snapshotsById.removeAll(keepingCapacity: true)
    }

    func value(for id: UUID) -> SidebarWorkspaceSnapshotBuilder.Snapshot? {
        _ = revision
        return snapshotsById[id]
    }

    /// Seeds an uncached value during parent projection without invalidating layout.
    func store(_ snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot, for id: UUID) {
        snapshotsById[id] = snapshot
    }

    /// Membership changes already invalidate the parent; pruning publishes nothing.
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
