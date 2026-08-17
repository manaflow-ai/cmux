/// Coalesces deferred main-actor work without linking replacement closures.
///
/// The stored task captures this scheduler weakly. Replacing an action cancels
/// and drops the scheduler's reference to the previous task before storing its
/// successor. The executor may retain canceled tasks until they drain, but they
/// cannot create a recursive release chain through prior queued work.
@MainActor
public final class MainActorDeferredActionScheduler {
    private let clock: any Clock<Duration>
    private var pendingTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Creates a scheduler driven by `clock`.
    ///
    /// - Parameter clock: The clock used for nonzero deadlines. Tests can
    ///   inject a controllable clock instead of waiting for wall time.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Whether an action is currently waiting to execute.
    public var isScheduled: Bool {
        pendingTask != nil
    }

    /// Cancels and releases the currently scheduled action, if any.
    public func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// Replaces any pending action with `action`.
    ///
    /// - Parameters:
    ///   - delay: The intended deadline before execution.
    ///   - zeroDelayPolicy: The enqueue behavior when `delay` is zero.
    ///   - action: Main-actor work to execute if it remains current.
    public func schedule(
        after delay: Duration = .zero,
        zeroDelayPolicy: MainActorDeferredActionZeroDelayPolicy = .enqueue,
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
            } else if zeroDelayPolicy == .yieldOnce {
                await Task.yield()
            }

            guard !Task.isCancelled else { return }
            guard let self, generation == scheduledGeneration else { return }
            pendingTask = nil
            action()
        }
    }

    deinit {
        pendingTask?.cancel()
    }
}
