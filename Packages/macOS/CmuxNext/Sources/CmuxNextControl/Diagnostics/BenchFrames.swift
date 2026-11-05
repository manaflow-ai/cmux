#if DEBUG || CMUX_BENCH_HOOKS
import Foundation
import CmuxNextCompat
public import CmuxNextSettings
import CmuxNextWakeups

/// Display-link frame intervals between `start` and `stop`, and when a bench's result first shows (`debug.new_tab` benches).
///
/// A waiter (``settled(until:start:window:deadline:)``) reads its condition at two points:
/// - each display-link tick: `visible`, the tick at which the condition first holds (what the bench returns);
/// - after each Core Animation commit of the main run loop: ``lastCommitted``, the end of the first commit after which the
///   condition holds. The render server shows a committed frame without the main thread, so a frame committed while the
///   main thread then stays busy is on screen before the next tick reaches the main thread: `visible` alone overstates it
///   (CMD-N FIRST FRAME, STATUS 14067).
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
    private var startedAt = ContinuousClock.now
    /// Ms from ``start()`` to the first display frame after it.
    private var firstTick: Double?
    /// Ms from the last waiter's start to the end of the first commit after which its condition held, or nil.
    public private(set) var lastCommitted: Double?

    private struct Waiter {
        var done: () -> Bool
        var start: ContinuousClock.Instant
        var window: Double
        var deadline: Double
        var visible: Double?
        var committed: Double?
        var continuation: CheckedContinuation<Double?, Never>
    }

    public init() {}

    /// Resumes with the ms at which `done` first held (checked each frame), once `window` ms of
    /// frames followed it, or nil at `deadline` ms. ``lastCommitted`` then holds its commit time.
    public func settled(until done: @escaping () -> Bool, start: ContinuousClock.Instant, window: Double, deadline: Double) async -> Double? {
        lastCommitted = nil
        commitWatch = MainRunLoopObserver(activities: .beforeWaiting, order: .max, drawsNothingAfterCommit: true) { [weak self] _ in
            self?.afterCommit()
        }
        return await withCheckedContinuation { continuation in
            waiter = Waiter(done: done, start: start, window: window, deadline: deadline, continuation: continuation)
        }
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
        guard var waiting = waiter, waiting.committed == nil, waiting.done() else { return }
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
