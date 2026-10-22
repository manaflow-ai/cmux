import AppKit
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.frames`: display-link frame intervals for the CLI storm bench.
/// Runs only between `start` and `stop`, and at most `maximumRun` (a client
/// that never sends `stop` must not keep the display link running).
/// A frame interval longer than the display's refresh period means the main
/// thread missed a vsync.
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
    /// Main-thread CPU (user + system) spent between consecutive frames, ms.
    private var mainWork: [Double] = []
    private var lastMainCPU: UInt64?
    static let capacity = 100_000

    func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            start()
        case "stop":
            let stats = self.stats
            stop()
            return stats
        case "reset":
            intervals.removeAll(keepingCapacity: true)
            mainWork.removeAll(keepingCapacity: true)
            last = 0
            lastMainCPU = nil
        default:
            break
        }
        return stats
    }

    private func start() {
        intervals.removeAll(keepingCapacity: true)
        mainWork.removeAll(keepingCapacity: true)
        last = 0
        lastMainCPU = nil
        client.activate()
        expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
    }

    private func stop() {
        client.deactivate()
        expiry.cancel()
    }

    private func tick(_ tick: FrameTick) {
        if let refresh = tick.refreshInterval { expected = refresh }
        if last > 0, intervals.count < Self.capacity { intervals.append((tick.timestamp - last) * 1_000) }
        last = tick.timestamp
        let cpu = currentThreadCPUNanos()
        if let cpu, let previous = lastMainCPU, mainWork.count < Self.capacity {
            mainWork.append(Double(cpu &- previous) / 1_000_000)
        }
        lastMainCPU = cpu
    }

    private var missedOffsets: [Double] {
        guard expected > 0 else { return [] }
        var offset = 0.0
        return intervals.compactMap { interval in
            offset += interval
            return interval > expected * 1_500 ? offset : nil
        }
    }

    private var stats: JSONValue {
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        let budget = 1_000.0 / 60.0
        let budget120 = 1_000.0 / 120.0
        let work = mainWork.sorted()
        func workPercentile(_ p: Double) -> Double {
            guard !work.isEmpty else { return 0 }
            return work[min(work.count - 1, Int((Double(work.count - 1) * p).rounded()))]
        }
        return [
            "running": .bool(client.isActive),
            "frames": JSONValue(sorted.count),
            "refresh_ms": .number(expected * 1_000),
            "p50_ms": .number(percentile(0.5)),
            "p95_ms": .number(percentile(0.95)),
            "p99_ms": .number(percentile(0.99)),
            "max_ms": .number(sorted.last ?? 0),
            "over_16_7_ms": JSONValue(sorted.filter { $0 > budget }.count),
            // Frames over a 120 Hz frame (ProMotion's budget), whatever the display's own refresh.
            "over_8_33_ms": JSONValue(sorted.filter { $0 > budget120 }.count),
            // Main-thread CPU between frames: what the app itself spent, independent of the display.
            "main_ms_total": .number(work.reduce(0, +)),
            "main_ms_p50": .number(workPercentile(0.5)),
            "main_ms_p95": .number(workPercentile(0.95)),
            "main_ms_max": .number(work.last ?? 0),
            "main_over_8_33_ms": JSONValue(work.filter { $0 > budget120 }.count),
            // Missed vsyncs: intervals longer than 1.5 refresh periods.
            "missed": JSONValue(expected > 0 ? sorted.filter { $0 > expected * 1_500 }.count : 0),
            // When the missed vsyncs happened: ms from the first frame to the end of each (at most 16).
            "missed_at_ms": .array(missedOffsets.prefix(16).map { .number($0.rounded()) }),
        ]
    }
}


/// The calling thread's CPU time (user + system), ns; nil when `thread_info` fails.
/// `debug.frames` ticks on the main thread, so this is the main thread's time.
private func currentThreadCPUNanos() -> UInt64? {
    let thread = pthread_mach_thread_np(pthread_self())  // no port reference to release, unlike mach_thread_self()
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(clamping: count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    guard result == KERN_SUCCESS else { return nil }
    let user = UInt64(clamping: info.user_time.seconds) * 1_000_000_000 + UInt64(clamping: info.user_time.microseconds) * 1_000
    let system = UInt64(clamping: info.system_time.seconds) * 1_000_000_000 + UInt64(clamping: info.system_time.microseconds) * 1_000
    return user + system
}
