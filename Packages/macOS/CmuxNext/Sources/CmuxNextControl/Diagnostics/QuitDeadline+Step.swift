import CmuxNextWakeups
import os

extension QuitDeadline {
    /// Writes a mark when a quit step ends (`quit.<name>`) or passes its limit
    /// (`quit.<name>.limit`); the App sets it to its launch-mark sink.
    @MainActor public static var stepMark: (String) -> Void = { _ in }

    /// Runs one quit step under a time limit (slow quit, 2026-10-20): the quit
    /// goes on when the step ends or when `limit` passes, whichever comes
    /// first; true when the step ended in time. A step past its limit keeps
    /// running, and the process still ends at the quit's deadline, so no step
    /// can hold a quit. A step that blocks the main thread cannot be raced
    /// here (the limit fires on the main actor too): the deadline's own thread
    /// ends the process then.
    @MainActor @discardableResult
    public static func step(_ name: String, limit: Duration, clock: any Clock<Duration> = ContinuousClock(),
                            _ body: @escaping @MainActor () async -> Void) async -> Bool {
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
        stepMark(ended ? "quit.\(name)" : "quit.\(name).limit")
        if !ended {
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                .error("quit step \(name, privacy: .public) passed its \(limit, privacy: .public) limit; the quit goes on")
        }
        return ended
    }
}

/// One race of ``QuitDeadline/step(_:limit:clock:_:)``: the first of the step
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
