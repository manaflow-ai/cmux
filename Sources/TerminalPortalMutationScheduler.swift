import Foundation

@MainActor
final class TerminalPortalMutationScheduler {
    private typealias Mutation = @MainActor () -> Void

    private var cancellationGeneration: UInt64 = 0
    private var pendingMutation: Mutation?
    private var pendingDrainCompletion: Mutation?
    private var drainTask: Task<Void, Never>?

    @discardableResult
    func schedule(
        _ mutation: @escaping @MainActor () -> Void,
        onDrain: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never> {
        pendingMutation = mutation
        // Keep only the latest cleanup alongside the coalesced mutation. A nil
        // completion must not discard cleanup registered by an earlier callback.
        if let onDrain {
            pendingDrainCompletion = onDrain
        }
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
                      let mutation = self.pendingMutation else { break }
                self.pendingMutation = nil
                mutation()
            }

            guard self.cancellationGeneration == scheduledCancellationGeneration else { return }
            self.drainTask = nil
            let completion = self.pendingDrainCompletion
            self.pendingDrainCompletion = nil
            completion?()
        }
        drainTask = task
        return task
    }

    func cancel() {
        cancellationGeneration &+= 1
        pendingMutation = nil
        drainTask?.cancel()
        drainTask = nil
        let completion = pendingDrainCompletion
        pendingDrainCompletion = nil
        completion?()
    }
}
