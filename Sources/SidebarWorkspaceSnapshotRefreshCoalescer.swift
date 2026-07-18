import Foundation

/// Batches keyed workspace refresh requests without publishing intermediate state.
///
/// Pending ids live in this non-observable owner. One callback on the next
/// common-mode run-loop turn lets concurrent workspace publishers converge
/// before the sidebar crosses its single `@State` publication boundary.
@MainActor
final class SidebarWorkspaceSnapshotRefreshCoalescer {
    private var pendingWorkspaceIds: Set<UUID> = []
    private var scheduledGeneration: UInt64?
    private var generation: UInt64 = 0

    func schedule(
        workspaceId: UUID,
        flush: @MainActor @escaping (Set<UUID>) -> Void
    ) {
        pendingWorkspaceIds.insert(workspaceId)
        guard scheduledGeneration == nil else { return }

        generation &+= 1
        let scheduledGeneration = generation
        self.scheduledGeneration = scheduledGeneration
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            // `RunLoop.main.perform` guarantees main-run-loop delivery, but
            // Foundation's closure is not annotated with `@MainActor`.
            MainActor.assumeIsolated {
                guard let self,
                      self.scheduledGeneration == scheduledGeneration else {
                    return
                }
                let workspaceIds = self.pendingWorkspaceIds
                self.pendingWorkspaceIds.removeAll(keepingCapacity: true)
                self.scheduledGeneration = nil
                guard !workspaceIds.isEmpty else { return }
                flush(workspaceIds)
            }
        }
    }

    /// Invalidates an enqueued callback and discards ids from the old lifecycle.
    func cancel() {
        generation &+= 1
        scheduledGeneration = nil
        pendingWorkspaceIds.removeAll(keepingCapacity: true)
    }
}
