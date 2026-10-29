#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.frames`: display-link frame intervals for the CLI storm bench.
/// Runs only between `start` and `stop`, and at most `maximumRun` (a client
/// that never sends `stop` must not keep the display link running). The cap
/// is read on the probe's own frames, so it needs no timer: the first frame
/// past it ends the run (idle-wakeups.md, an event before a timer).
/// A frame interval longer than the display's refresh period means the main
/// thread missed a vsync.
///
/// Per frame it also keeps the main thread's busy time since the previous
/// frame (`main_*`: the main run loop's awake time, ``MainRunLoopAwakeTime``'s
/// observers that exist only between `start` and `stop`) and the
/// `NSView.layout()` calls and window layout passes in it (`LayoutPassGuard`'s
/// counters), for the app gesture bench (scripts/cmux-next/app-perf.py).
/// `raw: true` adds the per-frame arrays to the reply.
///
/// `start` with `render: true` also arms ``RenderStats`` (DEBUG and bench
/// builds; a counting pass, never a timed one: its hooks cost time) and
/// replies once its hooks count (their first class scan runs off the main
/// thread); the frames start then. Every reply adds the render keys
/// (``RenderFrameLog/report(raw:)``), which stay readable after `stop`.
@MainActor
final class DebugFrameProbe {
    static let maximumRun: CFTimeInterval = 600
    private lazy var client = FrameClient(owner: "debug.frames", isAnimation: false, on: .app) { [weak self] tick in
        self?.frame(tick) ?? false
    }
    /// When the run started (CACurrentMediaTime base, the frames' clock).
    private var runStart: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var expected: Double = 0
    static let capacity = 100_000
    /// Per frame, parallel to `intervals`: main-thread ms, view layouts, window layout passes.
    private var busy: [Double] = []
    private var viewLayouts: [Int] = []
    private var windowLayouts: [Int] = []
    /// The main run loop's awake time since the last frame.
    private let awakeTime = MainRunLoopAwakeTime()
    private var layoutMark = (view: 0, window: 0)
    private let render: RenderFrameLog

    /// - Parameter render: per-frame counts of the app's one ``RenderStats`` (AppControl owns it).
    init(render: RenderFrameLog) { self.render = render }

    func handle(_ params: [String: JSONValue]) -> ControlReply {
        let raw = params["raw"]?.boolValue == true
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            if params["render"]?.boolValue == true { return .followUp { [self] in await startCounting(raw: raw) } }
            render.disarm()
            start()
        case "stop":
            let stats = stats(raw: raw)
            stop()
            return .value(stats)
        case "reset":
            clear()
        default:
            break
        }
        return .value(stats(raw: raw))
    }

    /// `start` with `render: true`: the frames start once the render hooks count (not after a `stop` that came first).
    private func startCounting(raw: Bool) async -> JSONValue {
        if await render.arm() { start() }
        return stats(raw: raw)
    }

    private func start() {
        clear()
        runStart = CACurrentMediaTime()
        client.activate()
        awakeTime.install()
    }

    private func stop() {
        client.deactivate()
        endRun()
    }

    /// The run's observers and render arms go; the frame client is idle already or made idle by the caller.
    private func endRun() {
        awakeTime.remove()
        render.disarm()
    }

    private func clear() {
        intervals.removeAll(keepingCapacity: true)
        busy.removeAll(keepingCapacity: true)
        viewLayouts.removeAll(keepingCapacity: true)
        windowLayouts.removeAll(keepingCapacity: true)
        last = 0
        awakeTime.reset()
        layoutMark = (LayoutPassGuard.shared.viewLayoutCalls, LayoutPassGuard.shared.windowLayoutPasses)
        render.clear()
    }

    /// One frame of the run; false once the run passed ``maximumRun`` (the client goes idle and the run ends).
    func frame(_ tick: FrameTick) -> Bool {
        guard tick.timestamp - runStart < Self.maximumRun else {
            endRun()
            return false
        }
        record(tick)
        return true
    }

    private func record(_ tick: FrameTick) {
        if let refresh = tick.refreshInterval { expected = refresh }
        let awake = awakeTime.take()
        let guardian = LayoutPassGuard.shared
        render.tick(record: last > 0 && intervals.count < Self.capacity)
        if last > 0, intervals.count < Self.capacity {
            intervals.append((tick.timestamp - last) * 1_000)
            busy.append(awake * 1_000)
            viewLayouts.append(guardian.viewLayoutCalls &- layoutMark.view)
            windowLayouts.append(guardian.windowLayoutPasses &- layoutMark.window)
        }
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
        for (key, value) in render.report(raw: raw) { stats[key] = JSONValue(foundation: value) }
        return .object(stats)
    }
}
#endif
