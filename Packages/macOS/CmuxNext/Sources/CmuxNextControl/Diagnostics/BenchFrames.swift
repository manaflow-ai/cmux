#if DEBUG || CMUX_BENCH_HOOKS
import Foundation
import CmuxNextCompat
public import CmuxNextSettings
import CmuxNextWakeups

/// Display-link frame intervals between `start` and `stop`, and when a bench's result first shows (`debug.new_tab` benches).
///
/// A waiter (``settled(until:start:window:deadline:watchCommits:)``) reads its condition each display-link tick: `visible`,
/// the tick at which the condition first holds (what the bench returns). With `watchCommits`, it also reads it after each
/// Core Animation commit of the main run loop until `visible`: ``lastCommitted``, the end of the first commit after which
/// the model holds the result, a lower bound for when it shows (the render server shows a committed frame without the main
/// thread, so `visible` alone overstates a frame committed while the main thread then stays busy; CMD-N FIRST FRAME, STATUS
/// 14067). It is nil when the result first held in the visible tick's own pass, before that pass committed; it can be set
/// while `visible` stays nil (the result held after one commit and never on a tick before the deadline). Only a
/// condition that reads, and does nothing else, may watch commits.
@MainActor
public final class BenchFrames {
    private lazy var client = FrameClient(owner: "debug.new_tab.frames", isAnimation: false, on: .app) { [weak self] tick in
        self?.tick(tick)
        return true
    }
    /// After the commit of every main run loop pass while a waiter waits; it lays out, displays and commits nothing.
    private var commitWatch: MainRunLoopObserver?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var refresh: Double = 0
    private var waiter: Waiter?
    /// The id of the last waiter (``Waiter/id``).
    private var waiters: UInt64 = 0
    private var startedAt = ContinuousClock.now
    /// Ms from ``start()`` to the first display frame after it.
    private var firstTick: Double?
    /// Ms from the last waiter's start to the end of the first commit after which its condition held, or nil.
    public private(set) var lastCommitted: Double?
    /// Tests only: runs as a waiter registers, just before its deadline is scheduled (a cancel that lands there).
    package var beforeSchedulingDeadline: (() -> Void)?

    private struct Waiter {
        var id: UInt64
        var done: () -> Bool
        var start: ContinuousClock.Instant
        var window: Double
        var deadline: Double
        var visible: Double?
        var committed: Double?
        var continuation: CheckedContinuation<Double?, Never>
        /// Ends the wait at its deadline when no display tick does.
        var timer: DemandTimer
    }

    /// The clock the waiters' deadline timers run on.
    private let clock: any Clock<Duration>

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Resumes with the ms at which `done` first held (checked each frame), once `window` ms of
    /// frames followed it, or nil at `deadline` ms. With `watchCommits` (a `done` that only reads), ``lastCommitted``
    /// then holds its commit time. The deadline holds without a display tick too (a window that
    /// stopped drawing), and a cancelled wait answers at once with what it saw: a capture scene
    /// never waits past its deadline.
    public func settled(until done: @escaping () -> Bool, start: ContinuousClock.Instant, window: Double, deadline: Double,
                        watchCommits: Bool = false) async -> Double? {
        lastCommitted = nil
        commitWatch = watchCommits ? MainRunLoopObserver(activities: .beforeWaiting, order: .max, drawsNothingAfterCommit: true) { [weak self] _ in
            self?.afterCommit()
        } : nil
        waiters &+= 1
        let id = waiters
        let timer = DemandTimer(owner: "debug.new_tab.frames.deadline", clock: clock)
        let left = max(deadline - Self.ms(.now - start), 0)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = Waiter(id: id, done: done, start: start, window: window, deadline: deadline, continuation: continuation, timer: timer)
                let cancelled = Task.isCancelled
                beforeSchedulingDeadline?()
                timer.schedule(after: .milliseconds(cancelled ? 0 : left)) { @MainActor [weak self] in self?.expire(id) }
            }
        } onCancel: {
            // A cancel ends the wait on the main actor, never by rescheduling the deadline timer: the
            // registration's own schedule could replace that (#41480 F1). The registration is one main-actor
            // job, so this hop runs after it and finds the waiter; a cancel before the registration read
            // `Task.isCancelled` also gave it a zero deadline.
            // task-owner: one hop that ends waiter `id`; it does nothing once that waiter has ended.
            Task { @MainActor [weak self] in self?.expire(id) }
        }
    }

    /// Waiter `id` reached its deadline with no tick to end it, or was cancelled.
    private func expire(_ id: UInt64) {
        guard let waiting = waiter, waiting.id == id else { return }
        finish(waiting, returning: waiting.visible)
    }

    public func start() {
        last = 0
        startedAt = .now
        firstTick = nil
        intervals.removeAll(keepingCapacity: true)
        client.activate()
    }

    public func stop() -> JSONValue {
        client.deactivate()
        commitWatch = nil
        let period = refresh * 1_000
        let missed = period > 0 ? intervals.filter { $0 > period * 1.5 }.count : 0
        return .object([
            "count": .number(Double(intervals.count)), "refresh_ms": .number(period),
            "max_ms": .number(intervals.max() ?? 0), "missed": .number(Double(missed)),
            "first_tick_ms": firstTick.map { .number($0) } ?? .null,
            "intervals_ms": .array(intervals.prefix(64).map { .number(($0 * 100).rounded() / 100) }),
        ])
    }

    private func afterCommit() {
        guard var waiting = waiter, waiting.committed == nil, waiting.visible == nil, waiting.done() else { return }
        waiting.committed = Self.ms(.now - waiting.start)
        waiter = waiting
    }

    private func tick(_ tick: FrameTick) {
        if let interval = tick.refreshInterval { refresh = interval }
        if firstTick == nil { firstTick = Self.ms(.now - startedAt) }
        if last > 0 { intervals.append((tick.timestamp - last) * 1_000) }
        last = tick.timestamp
        guard var waiting = waiter else { return }
        let now = Self.ms(.now - waiting.start)
        if waiting.visible == nil, waiting.done() { waiting.visible = now }
        if let visible = waiting.visible, now - visible >= waiting.window || now >= waiting.deadline {
            finish(waiting, returning: visible)
        } else if waiting.visible == nil, now >= waiting.deadline {
            finish(waiting, returning: nil)
        } else {
            waiter = waiting
        }
    }

    private func finish(_ waiting: Waiter, returning visible: Double?) {
        waiter = nil
        waiting.timer.cancel()
        commitWatch = nil
        lastCommitted = waiting.committed
        waiting.continuation.resume(returning: visible)
    }

    private static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
#endif
