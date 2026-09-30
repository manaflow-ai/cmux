import Foundation

/// Serializes graph publication for one provider. A forced reader waits for a
/// pass started after its request; ordinary readers share the active pass.
@MainActor
public final class CloudProviderRefreshCoordinator {
    public nonisolated init() {}

    private struct PassResult {
        let value: Bool
        let lifetime: UInt64
        let invalidation: UInt64
    }

    private struct Entry {
        let request: UInt64
        let forced: Bool
        let task: Task<PassResult, Never>
    }

    private var inFlight: Entry?
    private var latestRequest: UInt64 = 0
    private var invalidation: UInt64 = 0
    private var lifetime: UInt64 = 0
    /// Result of the most recently completed forced pass. This is retained
    /// briefly so callers that were already waiting on an older pass can join
    /// a trailing pass even if its owner clears `inFlight` first. Only the
    /// pass task writes this value; waiter continuations may resume after an
    /// invalidation and must never republish an old result.
    private var completedForcedPass: (request: UInt64, lifetime: UInt64, invalidation: UInt64, result: Bool)?

    public func refresh(force: Bool, operation: @escaping @MainActor (Bool) async -> Bool) async -> Bool {
        latestRequest &+= 1
        let request = latestRequest
        let epoch = lifetime
        // When a forced reader arrives during an older pass, all readers in
        // that burst need one trailing pass. Yield once before creating it so
        // continuations waiting on the same pass can join the trailing owner
        // instead of each starting an identical snapshot in sequence.
        var shouldCoalesceTrailingPass = false
        while !Task.isCancelled, epoch == lifetime {
            if let entry = inFlight {
                let outcome = await entry.task.value
                let result = outcome.value
                if inFlight?.task == entry.task { inFlight = nil }
                guard !Task.isCancelled, epoch == lifetime else { return false }
                // The pass can finish just before an invalidation is
                // delivered. Its waiter must not return or cache that stale
                // result; let the next pass observe the new metadata.
                guard outcome.lifetime == lifetime,
                      outcome.invalidation == invalidation else {
                    shouldCoalesceTrailingPass = force
                    continue
                }
                if !force || (entry.forced && entry.request >= request) { return result }
                shouldCoalesceTrailingPass = true
                continue
            }
            if shouldCoalesceTrailingPass {
                shouldCoalesceTrailingPass = false
                await Task.yield()
                if let completedForcedPass,
                   completedForcedPass.lifetime == epoch,
                   completedForcedPass.invalidation == invalidation,
                   completedForcedPass.request >= request {
                    return completedForcedPass.result
                }
                continue
            }
            // A waiter may resume after the owner has already cleared the
            // in-flight entry. Reuse that just-finished trailing pass rather
            // than opening another identical snapshot.
            if force,
               let completedForcedPass,
               completedForcedPass.lifetime == epoch,
               completedForcedPass.invalidation == invalidation,
               completedForcedPass.request >= request {
                return completedForcedPass.result
            }
            let task = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, epoch == self.lifetime {
                    let revision = self.invalidation
                    let result = await operation(force)
                    guard !Task.isCancelled, epoch == self.lifetime else {
                        return PassResult(value: false, lifetime: epoch, invalidation: revision)
                    }
                    // Metadata superseded this pass. Readers stay attached to
                    // the owner until a pass over the current metadata finishes.
                    if revision == self.invalidation {
                        if force {
                            self.completedForcedPass = (
                                request: request,
                                lifetime: epoch,
                                invalidation: revision,
                                result: result
                            )
                        }
                        return PassResult(value: result, lifetime: epoch, invalidation: revision)
                    }
                }
                return PassResult(value: false, lifetime: epoch, invalidation: self?.invalidation ?? 0)
            }
            // Covers all forced readers already waiting, so a burst shares
            // one trailing pass instead of issuing one snapshot per waiter.
            inFlight = Entry(request: latestRequest, forced: force, task: task)
        }
        return false
    }

    public func invalidate() {
        invalidation &+= 1
        completedForcedPass = nil
    }

    public func cancel() {
        lifetime &+= 1
        inFlight?.task.cancel()
        inFlight = nil
        completedForcedPass = nil
    }
}
