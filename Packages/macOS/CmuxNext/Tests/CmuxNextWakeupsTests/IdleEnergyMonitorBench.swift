import CmuxNextTestSupport
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The always-on cost of ``IdleEnergyMonitor/noteWake()`` per main run loop wake, in nanoseconds, over
/// the app's real counters (`CLOCK_UPTIME_RAW`, ``ExpectedActivity``'s input count and
/// ``ProcessUsage/interruptWakeups(of:)``) at a 120 Hz frame rate's worth of wakes. The budget is
/// < 100 ns per wake over its uptime read (perf-hot path `idle-energy-wake`); the
/// rusage read happens only when a window opens or closes. A measurement, not a gate: run it in a Release build on each macOS major
/// and quote the line. With CMUX_PERF_RESULT_DIR it also writes each number as result-v1 (lab story
/// swift-idle-energy-wake).
///
/// ```
/// CMUX_IDLE_ENERGY_BENCH=1 swift test -c release --filter IdleEnergyMonitorBench
/// ```
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_IDLE_ENERGY_BENCH"] == "1"))
struct IdleEnergyMonitorBench {
    /// About 2.3 hours of 120 Hz frames.
    private static let wakes = 1_000_000

    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static func wakeNanos(_ monitor: IdleEnergyMonitor) -> Double {
        let start = now()
        for _ in 0..<wakes { monitor.noteWake() }
        return Double(now() - start) / Double(wakes)
    }

    @Test func alwaysOnCostPerWake() throws {
        var clockSink: UInt64 = 0
        let clockStart = Self.now()
        for _ in 0..<Self.wakes { clockSink &+= Self.now() }
        let clockNanos = Double(Self.now() - clockStart) / Double(Self.wakes)

        let monitor = IdleEnergyMonitor(sources: .live(activity: ExpectedActivity()))
        _ = Self.wakeNanos(monitor)  // warm: the first wake starts the wait for idle
        let perWake = Self.wakeNanos(monitor)
        let rusageStart = Self.now()
        let rusage = ProcessUsage.interruptWakeups(of: getpid())
        let rusageNanos = Self.now() - rusageStart
        print(String(format: "idle-energy-wake bench: macOS %@, %d wakes: %.1f ns/wake, clock read %.1f ns, %.1f ns/wake over the clock read; one rusage read %llu ns (sink %llu)",
                     ProcessInfo.processInfo.operatingSystemVersionString, Self.wakes, perWake, clockNanos,
                     perWake - clockNanos, rusageNanos, clockSink & 1))
        if let results = try PerfResultWriter() {
            try results.record("swift.idle_energy_wake.wake_ns", unit: .ns, samples: [perWake])
            try results.record("swift.idle_energy_wake.clock_read_ns", unit: .ns, samples: [clockNanos])
            try results.record("swift.idle_energy_wake.rusage_read_ns", unit: .ns, samples: [rusageNanos])
        }
        #expect(rusage != nil)
    }
}
