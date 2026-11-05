public import AppKit
import CmuxNextCompat
import CmuxNextWakeups

/// `debug.frames`: display-link frame intervals for the CLI storm bench.
/// Runs only between `start` and `stop`, and at most `maximumRun` (a client
/// that never sends `stop` must not keep the display link running).
/// A frame interval longer than the display's refresh period means the main
/// thread missed a vsync.
///
/// Per frame it also keeps the main thread's busy time since the previous
/// frame (`main_*`: the main run loop's awake time, from two run-loop
/// observers that exist only between `start` and `stop`) and the
/// `NSView.layout()` calls and window layout passes in it (`LayoutPassGuard`'s
/// counters), for the app gesture bench (scripts/cmux-next/app-perf.py).
/// `raw: true` adds the per-frame arrays to the reply.
///
/// It also says why each missed refresh was late (``FrameMissSplit``): `missed_split` counts `main_late`, `commit_late`
/// and `presented_late`, and `missed_frames` lists the first misses with their stamps. A third observer, just before
/// Core Animation's commit, stamps the end of each turn's main work. The reply is plain Foundation values (the App's route makes it
/// the socket's JSON).
@MainActor
public final class DebugFrameProbe {
    static let maximumRun: Duration = .seconds(600)
    private lazy var client = FrameClient(owner: "debug.frames", isAnimation: false, on: .app) { [weak self] tick in
        self?.tick(tick)
        return true
    }
    private let expiry = DemandTimer(owner: "debug.frames.expiry")
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var expected: Double = 0
    static let capacity = 100_000
    /// Per frame, parallel to `intervals`: main-thread ms, view layouts, window layout passes.
    private var busy: [Double] = []
    private var layouts = FrameLayoutCounts()
    /// When the main run loop last woke (0 while it waits), and its awake time since the last frame.
    private var awakeSince: CFTimeInterval = 0
    private var awake: CFTimeInterval = 0
    private var observers: [CFRunLoopObserver] = []
    /// The missed refreshes' causes, and the current turn's stamps for it: when it woke and when its main work ended.
    private var split = FrameMissSplit()
    private var turnWoke: CFTimeInterval = 0
    private var turnMainEnd: CFTimeInterval?
    /// Just before Core Animation's commit (2,000,000) and the frame presenter's pass (1,999,999).
    static let mainEndOrder: CFIndex = 1_999_998

    public init() {}

    /// `action`: "start", "stop", "reset", or anything else to read the record; `raw` adds the per-frame arrays.
    public func handle(action: String?, raw: Bool) -> [String: Any] {
        switch action ?? "read" {
        case "start":
            start()
        case "stop":
            let stats = stats(raw: raw)
            stop()
            return stats
        case "reset":
            clear()
        default:
            break
        }
        return stats(raw: raw)
    }

    private func start() {
        clear()
        client.activate()
        watchMainRunLoop()
        expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
    }

    private func stop() {
        client.deactivate()
        layouts.stop()
        expiry.cancel()
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
    }

    private func clear() {
        intervals.removeAll(keepingCapacity: true)
        busy.removeAll(keepingCapacity: true)
        layouts.reset()
        last = 0
        awake = 0
        awakeSince = CACurrentMediaTime()
        split = FrameMissSplit()
        (turnWoke, turnMainEnd) = (awakeSince, nil)
    }

    /// Two observers of the main run loop: one when it wakes (first of the
    /// pass, `CFIndex.min`), one before it waits (last, `CFIndex.max`, after
    /// AppKit's layout and display and the Core Animation commit), so the time
    /// between them is the main thread's work. Removed by `stop`.
    private func watchMainRunLoop() {
        guard observers.isEmpty else { return }
        let woke = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.didWake() } // main-proof: an observer of the main run loop
        }
        // It only reads the clock: its context says so to the commit-boundary audit.
        let sleeps: CFRunLoopObserver? = MainRunLoopObserver.afterCommitObserver(activities: .beforeWaiting, order: CFIndex.max) { [weak self] _ in
            MainActor.assumeIsolated { self?.willWait() } // main-proof: an observer of the main run loop
        }
        let mainEnds = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, Self.mainEndOrder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.turnMainEnd = CACurrentMediaTime() } // main-proof: an observer of the main run loop
        }
        guard let woke, let sleeps, let mainEnds else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), woke, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), mainEnds, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleeps, .commonModes)
        observers = [woke, mainEnds, sleeps]
    }

    private func didWake() {
        awakeSince = CACurrentMediaTime()
        turnWoke = awakeSince
    }

    private func willWait() {
        let now = CACurrentMediaTime()
        split.turnEnded(woke: turnWoke, mainEnd: turnMainEnd, commitEnd: now)
        turnMainEnd = nil
        guard awakeSince > 0 else { return }
        awake += now - awakeSince
        awakeSince = 0
    }

    private func tick(_ tick: FrameTick) {
        if let refresh = tick.refreshInterval { expected = refresh }
        split.tick(timestamp: tick.timestamp, target: tick.targetTimestamp, refresh: expected, openTurnWoke: awakeSince > 0 ? turnWoke : nil)
        let now = CACurrentMediaTime()
        if awakeSince > 0 {
            awake += now - awakeSince
            awakeSince = now
        }
        let records = last > 0 && intervals.count < Self.capacity
        if records {
            intervals.append((tick.timestamp - last) * 1_000)
            busy.append(awake * 1_000)
        }
        layouts.frame(records: records)
        awake = 0
        last = tick.timestamp
    }

    private var missedOffsets: [Double] {
        guard expected > 0 else { return [] }
        var offset = 0.0
        return intervals.compactMap { interval in
            offset += interval
            return interval > expected * 1_500 ? offset : nil
        }
    }

    private func stats(raw: Bool) -> [String: Any] {
        let sorted = intervals.sorted()
        let work = busy.sorted()
        let budget = 1_000.0 / 60.0
        var stats: [String: Any] = [
            "running": client.isActive,
            "frames": sorted.count,
            "refresh_ms": expected * 1_000,
            "p50_ms": sorted.sortedPercentile(0.5),
            "p95_ms": sorted.sortedPercentile(0.95),
            "p99_ms": sorted.sortedPercentile(0.99),
            "max_ms": sorted.last ?? 0,
            "over_16_7_ms": sorted.filter { $0 > budget }.count,
            // Missed vsyncs: intervals longer than 1.5 refresh periods.
            "missed": expected > 0 ? sorted.filter { $0 > expected * 1_500 }.count : 0,
            // When the missed vsyncs happened: ms from the first frame to the end of each (at most 16).
            "missed_at_ms": missedOffsets.prefix(16).map { $0.rounded() },
            // The main thread's busy ms per frame; over 8.33 ms misses a 120 Hz vsync.
            "main_p50_ms": work.sortedPercentile(0.5),
            "main_p95_ms": work.sortedPercentile(0.95),
            "main_max_ms": work.last ?? 0,
            "main_total_ms": busy.reduce(0, +),
            "main_over_8_3_ms": work.filter { $0 > 1_000.0 / 120.0 }.count,
        ].merging(layouts.report(raw: raw)) { $1 }.merging(split.report) { $1 }
        if raw {
            stats["intervals_ms"] = intervals.map { ($0 * 100).rounded() / 100 }
            stats["main_ms"] = busy.map { ($0 * 100).rounded() / 100 }
        }
        return stats
    }
}
