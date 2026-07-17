import Foundation

/// Accumulates changed workspace identities until a merged observation burst settles.
@MainActor
final class SidebarWorkspaceObservationBatch {
    private var workspaceIds: Set<UUID> = []

    func insert(_ workspaceId: UUID) {
        workspaceIds.insert(workspaceId)
    }

    func take() -> Set<UUID> {
        defer { workspaceIds.removeAll(keepingCapacity: true) }
        return workspaceIds
    }
}
