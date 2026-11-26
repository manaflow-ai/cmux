import AppKit
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.main_cpu` {action: start | stop | read}: per display frame, the main
/// thread's CPU time (user + system, `thread_info`) since the previous frame and
/// the frame interval, for the animation bench (scripts/cmux-next/anim-perf-terminal.py).
/// A frame of a 120 Hz display has 8.33 ms; main-thread CPU over that in one
/// frame is a dropped ProMotion frame whatever the runner's own display does.
/// Runs only between `start` and `stop`, at most `maximumRun`.
@MainActor
final class DebugMainCPUProbe {
    static let maximumRun: Duration = .seconds(600)
    static let capacity = 100_000
    static let frame120Ms = 1_000.0 / 120.0
    private lazy var client = FrameClient(owner: "debug.main_cpu", isAnimation: false, on: .app) { [weak self] tick in
        self?.tick(tick)
        return true
    }
    private let expiry = DemandTimer(owner: "debug.main_cpu.expiry")
    private var lastTimestamp: CFTimeInterval = 0
    private var lastCPU: UInt64?
    private var intervals: [Double] = []
    private var work: [Double] = []

    func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start":
            intervals.removeAll(keepingCapacity: true)
            work.removeAll(keepingCapacity: true)
            lastTimestamp = 0
            lastCPU = currentThreadCPUNanos()
            client.activate()
            expiry.schedule(after: Self.maximumRun) { @MainActor [weak self] in self?.stop() }
        case "stop":
            // The work since the last frame counts too: a gesture that ends in a long main-thread slice.
            if let now = currentThreadCPUNanos(), let previous = lastCPU { work.append(Double(now &- previous) / 1_000_000) }
            let stats = self.stats
            stop()
            return stats
        default:
            break
        }
        return stats
    }

    private func stop() {
        client.deactivate()
        expiry.cancel()
    }

    private func tick(_ tick: FrameTick) {
        let cpu = currentThreadCPUNanos()
        if lastTimestamp > 0, intervals.count < Self.capacity {
            intervals.append((tick.timestamp - lastTimestamp) * 1_000)
        }
        if let cpu, let previous = lastCPU, work.count < Self.capacity {
            work.append(Double(cpu &- previous) / 1_000_000)
        }
        lastCPU = cpu
        lastTimestamp = tick.timestamp
    }

    private var stats: JSONValue {
        let frames = intervals.sorted(), slices = work.sorted()
        return [
            "running": .bool(client.isActive),
            "frames": JSONValue(frames.count),
            "over_8_33_ms": JSONValue(frames.filter { $0 > Self.frame120Ms }.count),
            "main_ms_total": .number(work.reduce(0, +)),
            "main_ms_p50": .number(percentile(slices, 0.5)),
            "main_ms_p95": .number(percentile(slices, 0.95)),
            "main_ms_max": .number(slices.last ?? 0),
            "main_over_8_33_ms": JSONValue(slices.filter { $0 > Self.frame120Ms }.count),
        ]
    }
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

/// The calling thread's CPU time (user + system), ns; nil when `thread_info` fails.
/// `debug.main_cpu` runs on the main thread, so this is the main thread's time.
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
