import Foundation

/// Serializes graph publication for one provider. A forced reader waits for a
/// pass started after its request; ordinary readers share the active pass.
@MainActor
final class CloudProviderRefreshCoordinator {
    private struct Entry {
        let request: UInt64
        let forced: Bool
        let task: Task<Bool, Never>
    }

    private var inFlight: Entry?
    private var latestRequest: UInt64 = 0
    private var invalidation: UInt64 = 0
    private var lifetime: UInt64 = 0

    func refresh(force: Bool, operation: @escaping @MainActor (Bool) async -> Bool) async -> Bool {
        latestRequest &+= 1
        let request = latestRequest
        let epoch = lifetime
        while !Task.isCancelled, epoch == lifetime {
            if let entry = inFlight {
                let result = await entry.task.value
                if inFlight?.task == entry.task { inFlight = nil }
                guard !Task.isCancelled, epoch == lifetime else { return false }
                if !force || (entry.forced && entry.request >= request) { return result }
                continue
            }
            let task = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, epoch == self.lifetime {
                    let revision = self.invalidation
                    let result = await operation(force)
                    guard !Task.isCancelled, epoch == self.lifetime else { return false }
                    // Metadata superseded this pass. Readers stay attached to
                    // the owner until a pass over the current metadata finishes.
                    if revision == self.invalidation { return result }
                }
                return false
            }
            // Covers all forced readers already waiting, so a burst shares
            // one trailing pass instead of issuing one snapshot per waiter.
            inFlight = Entry(request: latestRequest, forced: force, task: task)
        }
        return false
    }

    func invalidate() { invalidation &+= 1 }

    func cancel() {
        lifetime &+= 1
        inFlight?.task.cancel()
        inFlight = nil
    }
}
