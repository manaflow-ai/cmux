import Foundation

/// Coalesces deferred main-actor work without linking replacement closures.
///
/// The stored task captures this scheduler weakly. Replacing an action cancels
/// and drops the scheduler's reference to the previous task before storing its
/// successor. The executor may retain canceled tasks until they drain, but they
/// cannot create a recursive release chain through prior queued work.
@MainActor
final class MainActorDeferredActionScheduler {
    private let clock: any Clock<Duration>
    private var pendingTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    var isScheduled: Bool {
        pendingTask != nil
    }

    func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    func schedule(
        after delay: Duration = .zero,
        _ action: @escaping @MainActor () -> Void
    ) {
        cancel()

        let scheduledGeneration = generation
        pendingTask = Task { @MainActor [weak self, clock] in
            if delay > .zero {
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
            } else {
                guard !Task.isCancelled else { return }
            }

            guard let self, generation == scheduledGeneration else { return }
            pendingTask = nil
            action()
        }
    }

    deinit {
        pendingTask?.cancel()
    }
}
