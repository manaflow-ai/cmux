import CmuxNextWakeups
import os

/// Runs the quit's steps, each under a time limit (slow quit, 2026-10-20):
/// the quit goes on when a step ends or when its limit passes, whichever
/// comes first. A step past its limit keeps running beside the next steps,
/// and the quit waits for it before it replies to AppKit
/// (``finishOverruns(within:excluding:)``), at most for what is left of its
/// deadline (``QuitDeadline``), so a late step still writes and no step can
/// hold a quit. A step that blocks the main thread cannot be raced here (the
/// limit fires on the main actor too): the deadline's own thread ends the
/// process then.
///
/// The App builds one per quit coordinator and gives it its launch-mark
/// sink, so a run of the quit-launch bound reads each step's end.
@MainActor
public final class QuitStepLimiter {
    private let mark: @MainActor (String) -> Void
    private let clock: any Clock<Duration>
    /// The steps that passed their limit, by name, while they still run.
    private var overruns: [(name: String, task: Task<Void, Never>)] = []

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
        // task-owner: one quit step; past its limit the quit awaits it in finishOverruns, up to its deadline.
        let step = Task { @MainActor in
            await body()
            race.finish(true)
        }
        let ended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            race.continuation = continuation
            race.timer.schedule(after: limit) { @MainActor in race.finish(false) }
            if race.ended { race.finish(true) }
        }
        if !ended { overruns.append((name, step)) }
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
        let waited = overruns.filter { !excluding.contains($0.name) }
        overruns.removeAll { entry in waited.contains { $0.task == entry.task } }
        guard !waited.isEmpty else { return true }
        guard limit > .zero else {
            // No time is left before the deadline: the steps go on until it ends the process.
            overruns.append(contentsOf: waited)
            mark("quit.overruns.limit")
            return false
        }
        let race = QuitStepRace(owner: "quit.overruns", clock: clock)
        // task-owner: awaits the late steps; the race below bounds the quit's wait for it.
        let all = Task { @MainActor in
            for entry in waited { await entry.task.value }
            race.finish(true)
        }
        let ended = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            race.continuation = continuation
            race.timer.schedule(after: limit) { @MainActor in race.finish(false) }
            if race.ended { race.finish(true) }
        }
        if !ended {
            // A step still running at the deadline: the deadline's thread ends the process around it.
            overruns.append(contentsOf: waited)
            all.cancel()
            Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
                .error("quit steps \(waited.map(\.name).joined(separator: ","), privacy: .public) still ran after \(limit, privacy: .public)")
        }
        mark(ended ? "quit.overruns" : "quit.overruns.limit")
        return ended
    }
}

/// One race of ``QuitStepLimiter/run(_:limit:_:)``: the first of the step
/// and its timer resumes the waiter, once.
@MainActor
final class QuitStepRace {
    var continuation: CheckedContinuation<Bool, Never>?
    let timer: DemandTimer
    /// The step ended before its waiter began to wait: the waiter resumes at once.
    private(set) var ended = false

    init(owner: String, clock: any Clock<Duration>) {
        timer = DemandTimer(owner: owner, clock: clock)
    }

    func finish(_ ended: Bool) {
        if ended { self.ended = true }
        guard let continuation else { return }
        timer.cancel()
        continuation.resume(returning: ended)
        self.continuation = nil
    }
}
