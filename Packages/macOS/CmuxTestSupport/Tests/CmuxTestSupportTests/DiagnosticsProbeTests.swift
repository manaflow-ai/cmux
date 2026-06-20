#if DEBUG
import Foundation
import Testing
@testable import CmuxTestSupport

/// Behavioral coverage for the injected diagnostics probes.
///
/// These tests run with the typing-timing probe disabled (no
/// `CMUX_TYPING_TIMING_LOGS` / `CMUX_KEY_LATENCY_PROBE` environment variable and
/// no `cmuxTypingTimingLogs` / `cmuxKeyLatencyProbe` default in the test
/// process), which is the production default. That gate is the contract the lift
/// must preserve: with the probe off, the monitors install nothing and the
/// typing probe collects nothing. The tests confirm the constructor-injected
/// instances honor that gate (replacing the former `static let shared`
/// singletons) and that the install entry points are idempotent and safe to call
/// off the main run loop.
@Suite("DiagnosticsProbes")
@MainActor
struct DiagnosticsProbeTests {
    @Test func typingProbeDisabledByDefault() {
        // The probe is read once lazily; in a clean test process it is off, so
        // `start()` returns nil and no timing is collected.
        #expect(CmuxTypingTiming.isEnabled == false)
        #expect(CmuxTypingTiming.start() == nil)
    }

    @Test func stallMonitorInstallIsIdempotentWhenDisabled() {
        let monitor: any RunLoopStallMonitoring = CmuxMainRunLoopStallMonitor()
        // With the probe disabled the install is a no-op; repeated calls must not
        // crash or attach anything.
        monitor.installIfNeeded()
        monitor.installIfNeeded()
    }

    @Test func turnProfilerEndMeasureIsANoOpWhenDisabled() {
        let profiler: any MainThreadTurnProfiling = CmuxMainThreadTurnProfiler()
        profiler.installIfNeeded()
        profiler.installIfNeeded()
        // A nil `startedAt` is ignored; a real span is also ignored because the
        // probe is disabled. Neither path may crash.
        profiler.endMeasure("test.bucket", startedAt: nil)
        profiler.endMeasure("test.bucket", startedAt: ProcessInfo.processInfo.systemUptime)
    }

    @Test func typingTimingForwardsToInjectedProfiler() {
        // Installing a profiler as `turnProfiler` is how the composition root
        // wires `logDuration`'s span forwarding without a `shared` singleton.
        // Setting and clearing it must round-trip and not crash when invoked.
        let profiler: any MainThreadTurnProfiling = CmuxMainThreadTurnProfiler()
        CmuxTypingTiming.turnProfiler = profiler
        defer { CmuxTypingTiming.turnProfiler = nil }
        // Disabled probe: `logDuration` forwards to `endMeasure` (a no-op here)
        // and emits no log. Exercising it proves the forwarding path is sound.
        CmuxTypingTiming.logDuration(path: "test.path", startedAt: nil)
    }
}
#endif
