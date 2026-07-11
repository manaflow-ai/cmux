import Foundation

@MainActor
final class TerminalPortalMutationScheduler {
    private typealias Mutation = @MainActor () -> Void
    private typealias DrainCompletion = @MainActor () -> Void

    private var cancellationGeneration: UInt64 = 0
    private var pendingMutation: Mutation?
    private var pendingDrainCompletion: DrainCompletion?
    private var drainTask: Task<Void, Never>?

    @discardableResult
    func schedule(
        afterDrain: (@MainActor () -> Void)? = nil,
        _ mutation: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        pendingMutation = mutation
        // A schedule without cleanup must preserve a candidate cleanup already
        // attached to this drain. A newer candidate replaces it with its token.
        if let afterDrain {
            pendingDrainCompletion = afterDrain
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
            let completion = self.pendingDrainCompletion
            self.pendingDrainCompletion = nil
            self.drainTask = nil
            completion?()
        }
        drainTask = task
        return task
    }

    func cancel() {
        cancellationGeneration &+= 1
        pendingMutation = nil
        pendingDrainCompletion = nil
        drainTask?.cancel()
        drainTask = nil
    }
}
