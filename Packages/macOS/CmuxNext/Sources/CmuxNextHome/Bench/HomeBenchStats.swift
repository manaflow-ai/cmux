import Darwin
import Foundation

/// Frame statistics of one bench scenario: display-link intervals, run-loop
/// busy time and main-thread CPU per frame.
final class HomeBenchStats {
    var intervals: [Double] = []
    var busy: [Double] = []
    var cpu: [Double] = []
    var refresh = 1.0 / 120

    static func ms(_ seconds: Double) -> Double { (seconds * 1000 * 100).rounded() / 100 }

    private static func percentile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
    }

    func json() -> [String: Any] {
        // a hitch: a frame interval over 1.5 refresh periods (a dropped frame)
        let hitches = intervals.filter { $0 > refresh * 1.5 }
        let hitchTime = hitches.reduce(0) { $0 + ($1 - refresh) }
        let seconds = max(intervals.reduce(0, +), 1e-9)
        return [
            "frames": intervals.count,
            "hitches": hitches.count,
            "hitchTimeRatioMsPerS": Self.ms(hitchTime / seconds),
            "refreshMs": Self.ms(refresh),
            "frameIntervalMs": ["p50": Self.ms(Self.percentile(intervals, 0.5)), "p99": Self.ms(Self.percentile(intervals, 0.99)),
                                "max": Self.ms(intervals.max() ?? 0)],
            "maxMainThreadWorkMs": Self.ms(busy.max() ?? 0),
            "mainThreadWorkP99Ms": Self.ms(Self.percentile(busy, 0.99)),
            "maxMainThreadCpuMs": Self.ms(cpu.max() ?? 0),
            "mainThreadCpuP99Ms": Self.ms(Self.percentile(cpu, 0.99)),
            "framesOverBudgetCpu": cpu.filter { $0 > refresh }.count,
        ]
    }
}

/// Process measurements for the bench.
enum HomeBenchProbe {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    /// 1-minute load average.
    static func load1() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? (loads[0] * 100).rounded() / 100 : -1
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? (Double(info.resident_size) / 1_048_576 * 10).rounded() / 10 : -1
    }
}
