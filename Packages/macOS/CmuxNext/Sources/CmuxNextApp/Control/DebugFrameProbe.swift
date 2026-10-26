import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
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
@MainActor
final class DebugFrameProbe {
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
    private var viewLayouts: [Int] = []
    private var windowLayouts: [Int] = []
    /// When the main run loop last woke (0 while it waits), and its awake time since the last frame.
    private var awakeSince: CFTimeInterval = 0
    private var awake: CFTimeInterval = 0
    private var layoutMark = (view: 0, window: 0)
    private var observers: [CFRunLoopObserver] = []

    func handle(_ params: [String: JSONValue]) -> JSONValue {
        let raw = params["raw"]?.boolValue == true
        switch params["action"]?.stringValue ?? "read" {
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
        expiry.cancel()
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
    }

    private func clear() {
        intervals.removeAll(keepingCapacity: true)
        busy.removeAll(keepingCapacity: true)
        viewLayouts.removeAll(keepingCapacity: true)
        windowLayouts.removeAll(keepingCapacity: true)
        last = 0
        awake = 0
        awakeSince = CACurrentMediaTime()
        layoutMark = (LayoutPassGuard.shared.viewLayoutCalls, LayoutPassGuard.shared.windowLayoutPasses)
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
        let sleeps = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.willWait() } // main-proof: an observer of the main run loop
        }
        guard let woke, let sleeps else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), woke, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), sleeps, .commonModes)
        observers = [woke, sleeps]
    }

    private func didWake() {
        awakeSince = CACurrentMediaTime()
    }

    private func willWait() {
        guard awakeSince > 0 else { return }
        awake += CACurrentMediaTime() - awakeSince
        awakeSince = 0
    }

    private func tick(_ tick: FrameTick) {
        if let refresh = tick.refreshInterval { expected = refresh }
        let now = CACurrentMediaTime()
        if awakeSince > 0 {
            awake += now - awakeSince
            awakeSince = now
        }
        let guardian = LayoutPassGuard.shared
        if last > 0, intervals.count < Self.capacity {
            intervals.append((tick.timestamp - last) * 1_000)
            busy.append(awake * 1_000)
            viewLayouts.append(guardian.viewLayoutCalls &- layoutMark.view)
            windowLayouts.append(guardian.windowLayoutPasses &- layoutMark.window)
        }
        awake = 0
        layoutMark = (guardian.viewLayoutCalls, guardian.windowLayoutPasses)
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

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private func stats(raw: Bool) -> JSONValue {
        let sorted = intervals.sorted()
        let work = busy.sorted()
        let budget = 1_000.0 / 60.0
        var stats: [String: JSONValue] = [
            "running": .bool(client.isActive),
            "frames": JSONValue(sorted.count),
            "refresh_ms": .number(expected * 1_000),
            "p50_ms": .number(Self.percentile(sorted, 0.5)),
            "p95_ms": .number(Self.percentile(sorted, 0.95)),
            "p99_ms": .number(Self.percentile(sorted, 0.99)),
            "max_ms": .number(sorted.last ?? 0),
            "over_16_7_ms": JSONValue(sorted.filter { $0 > budget }.count),
            // Missed vsyncs: intervals longer than 1.5 refresh periods.
            "missed": JSONValue(expected > 0 ? sorted.filter { $0 > expected * 1_500 }.count : 0),
            // When the missed vsyncs happened: ms from the first frame to the end of each (at most 16).
            "missed_at_ms": .array(missedOffsets.prefix(16).map { .number($0.rounded()) }),
            // The main thread's busy ms per frame; over 8.33 ms misses a 120 Hz vsync.
            "main_p50_ms": .number(Self.percentile(work, 0.5)),
            "main_p95_ms": .number(Self.percentile(work, 0.95)),
            "main_max_ms": .number(work.last ?? 0),
            "main_total_ms": .number(busy.reduce(0, +)),
            "main_over_8_3_ms": JSONValue(work.filter { $0 > 1_000.0 / 120.0 }.count),
            "view_layouts": JSONValue(viewLayouts.reduce(0, +)),
            "view_layouts_max": JSONValue(viewLayouts.max() ?? 0),
            "window_layouts": JSONValue(windowLayouts.reduce(0, +)),
        ]
        if raw {
            stats["intervals_ms"] = .array(intervals.map { .number(($0 * 100).rounded() / 100) })
            stats["main_ms"] = .array(busy.map { .number(($0 * 100).rounded() / 100) })
            stats["view_layouts_per_frame"] = .array(viewLayouts.map { JSONValue($0) })
            stats["window_layouts_per_frame"] = .array(windowLayouts.map { JSONValue($0) })
        }
        return .object(stats)
    }
}
