import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chromium perf (Leo's audit, msg 9136): Chromium's work runs on the main
/// thread in passes of up to CEF's 10 ms slice. The pump records how long
/// each pass held the main thread, so a bench reads p50/p95 and the longest
/// pass between two `debug.cef` reads.
@MainActor
@Suite struct CEFMessagePumpPassTimeTests {
    private final class FakeTimer: CEFPumpTimer {
        var onFire: (() -> Void)?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) {}
        func disarm() {}
        func invalidate() {}
    }

    @Test func passesLandInTheirDurationBucket() {
        var now: TimeInterval = 0
        var durations: [TimeInterval] = [0.0001, 0.0004, 0.0008, 0.003, 0.012]
        let pump = CEFMessagePump(
            work: { now += durations.removeFirst() },
            safetyNet: .none,
            timer: FakeTimer(),
            clock: { now },
            ledger: WakeupLedger()
        )
        pump.start()
        for _ in 0..<5 { pump.pumpNow() }
        let histogram = pump.stats.passHistogram
        #expect(histogram.count == CEFPumpStats.passBucketUpperBounds.count + 1)
        // <0.25 ms, <0.5 ms, <1 ms, <2 ms, <5 ms, <10 ms, >= 10 ms
        #expect(histogram == [1, 1, 1, 0, 1, 0, 1])
        #expect(abs(pump.stats.maxPassSeconds - 0.012) < 1e-9)
    }
}
