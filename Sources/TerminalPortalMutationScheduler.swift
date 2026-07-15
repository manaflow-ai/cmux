import Foundation

@MainActor
final class TerminalPortalMutationScheduler {
    private typealias Mutation = @MainActor () -> Void
    private typealias Completion = @MainActor () -> Void

    private struct PendingWork {
        let mutation: Mutation
        let completion: Completion?
    }

    private var cancellationGeneration: UInt64 = 0
    private var pendingWork: PendingWork?
    private var drainTask: Task<Void, Never>?

    /// `onCompletion` runs exactly once when its mutation executes, is superseded,
    /// or is canceled.
    @discardableResult
    func schedule(
        onCompletion: (@MainActor () -> Void)? = nil,
        _ mutation: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        let supersededWork = pendingWork
        pendingWork = PendingWork(mutation: mutation, completion: onCompletion)
        // Cleanup belongs to the mutation it was registered with. Running it
        // when that mutation is replaced keeps coalescing storage bounded.
        supersededWork?.completion?()
        if let drainTask {
            return drainTask
        }

        let scheduledCancellationGeneration = cancellationGeneration

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.cancellationGeneration == scheduledCancellationGeneration {
                // Leave the SwiftUI/AppKit callback stack before every commit.
                // Schedules during the yield replace one pending snapshot instead
                // of canceling and multiplying tasks under layout churn.
                await Task.yield()
                guard !Task.isCancelled,
                      self.cancellationGeneration == scheduledCancellationGeneration,
                      let work = self.pendingWork else { break }
                self.pendingWork = nil
                work.mutation()
                work.completion?()
            }

            guard self.cancellationGeneration == scheduledCancellationGeneration else { return }
            self.drainTask = nil
        }
        drainTask = task
        return task
    }

    func cancel() {
        cancellationGeneration &+= 1
        let pendingWork = pendingWork
        self.pendingWork = nil
        drainTask?.cancel()
        drainTask = nil
        pendingWork?.completion?()
    }
}
