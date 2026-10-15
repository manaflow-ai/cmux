import Foundation

/// A ``BrowserEngineWarmupTimer`` that sleeps on an injected clock.
///
/// It is a bounded, intentional delay owned by one task; cancelling or
/// rescheduling cancels that task, so nothing polls.
@MainActor
public final class BrowserEngineWarmupClockTimer: BrowserEngineWarmupTimer {
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Creates a timer.
    /// - Parameter clock: The clock to sleep on; `ContinuousClock` by default
    ///   so time spent asleep counts.
    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    public var isScheduled: Bool { task != nil }

    public func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        generation &+= 1
        let expected = generation
        let clock = clock
        task = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.generation == expected else { return }
            self.task = nil
            fire()
        }
    }

    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
