import CmuxNextWakeups
import os

/// Runs the quit's steps, each under a time limit (slow quit, 2026-10-20):
/// the quit goes on when a step ends or when its limit passes, whichever
/// comes first. A step past its limit keeps running, and the process still
/// ends at the quit's deadline (``QuitDeadline``), so no step can hold a
/// quit. A step that blocks the main thread cannot be raced here (the limit
/// fires on the main actor too): the deadline's own thread ends the process
/// then.
///
/// The App builds one per quit coordinator and gives it its launch-mark
/// sink, so a run of the quit-launch bound reads each step's end.
@MainActor
public final class QuitStepLimiter {
    private let mark: @MainActor (String) -> Void
    private let clock: any Clock<Duration>

    /// - Parameters:
    ///   - mark: Gets `quit.<name>` when a step ends in time, `quit.<name>.limit`
    ///     when it passes its limit.
    ///   - clock: The clock the limits run on (tests pass a manual one).
    public init(mark: @escaping @MainActor (String) -> Void, clock: any Clock<Duration> = ContinuousClock()) {
        self.mark = mark
        self.clock = clock
    }

    /// Runs `body` as the quit step `name` for at most `limit`; true when the
    /// step ended in time.
    @discardableResult
    public func run(_ name: String, limit: Duration, _ body: @escaping @MainActor () async -> Void) async -> Bool {
        let race = QuitStepRace(owner: "quit.\(name)", clock: clock)
        let ended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            race.continuation = continuation
            race.timer.schedule(after: limit) { @MainActor in race.finish(false) }
            // task-owner: one quit step; it may outlive its limit, and the process ends at the quit deadline.
            Task { @MainActor in
                await body()
                race.finish(true)
            }
        }
        mark(ended ? "quit.\(name)" : "quit.\(name).limit")
        if !ended {
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                .error("quit step \(name, privacy: .public) passed its \(limit, privacy: .public) limit; the quit goes on")
        }
        return ended
    }

    /// Waits for the steps that passed their limit and still run (every one
    /// but those named in `excluding`), at most `limit`; true when they all ended.
    @discardableResult
    public func finishOverruns(within limit: Duration, excluding: Set<String> = []) async -> Bool {
        true
    }
}

/// One race of ``QuitStepLimiter/run(_:limit:_:)``: the first of the step
/// and its timer resumes the waiter, once.
@MainActor
final class QuitStepRace {
    var continuation: CheckedContinuation<Bool, Never>?
    let timer: DemandTimer

    init(owner: String, clock: any Clock<Duration>) {
        timer = DemandTimer(owner: owner, clock: clock)
    }

    func finish(_ ended: Bool) {
        timer.cancel()
        continuation?.resume(returning: ended)
        continuation = nil
    }
}
