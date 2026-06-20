import Testing

@testable import CmuxTerminal

@Suite("Scroll lag probe")
struct ScrollLagProbeTests {
    @Test func captureRequiresSustainedLag() {
        let cases: [(samples: Int, averageMs: Double, maxMs: Double, expected: Bool)] = [
            (4, 18, 85, false),
            (10, 6, 85, false),
            (10, 18, 35, false),
            (10, 18, 85, true),
        ]
        for testCase in cases {
            #expect(
                ScrollLagProbe.shouldCaptureScrollLagEvent(
                    samples: testCase.samples,
                    averageMs: testCase.averageMs,
                    maxMs: testCase.maxMs,
                    thresholdMs: 40,
                    nowUptime: 1000,
                    lastReportedUptime: nil
                ) == testCase.expected
            )
        }
    }

    @Test func captureRespectsCooldownWindow() {
        #expect(
            !ScrollLagProbe.shouldCaptureScrollLagEvent(
                samples: 12,
                averageMs: 22,
                maxMs: 90,
                thresholdMs: 40,
                nowUptime: 1200,
                lastReportedUptime: 1005,
                cooldown: 300
            )
        )
        #expect(
            ScrollLagProbe.shouldCaptureScrollLagEvent(
                samples: 12,
                averageMs: 22,
                maxMs: 90,
                thresholdMs: 40,
                nowUptime: 1406,
                lastReportedUptime: 1005,
                cooldown: 300
            )
        )
    }

    @Test func momentumScrollSessionReportsSustainedLag() {
        var reports: [ScrollLagReport] = []
        let probe = ScrollLagProbe { reports.append($0) }

        probe.markScrollActivity(hasMomentum: true, momentumEnded: false)
        #expect(probe.isScrolling)
        for _ in 0..<10 {
            probe.recordTickSample(elapsedMs: 50)
        }
        probe.markScrollActivity(hasMomentum: false, momentumEnded: true)

        #expect(!probe.isScrolling)
        #expect(reports.count == 1)
        #expect(reports.first?.samples == 10)
        #expect(reports.first?.maxMs == 50)
    }

    @Test func samplesOutsideScrollSessionAreIgnored() {
        var reports: [ScrollLagReport] = []
        let probe = ScrollLagProbe { reports.append($0) }

        probe.recordTickSample(elapsedMs: 100)
        probe.markScrollActivity(hasMomentum: true, momentumEnded: false)
        probe.markScrollActivity(hasMomentum: false, momentumEnded: true)

        #expect(reports.isEmpty)
    }

    @MainActor
    @Test func mouseWheelDebounceEndsSessionAfterClockElapses() async {
        var reports: [ScrollLagReport] = []
        let probe = ScrollLagProbe(clock: ImmediateClock()) { reports.append($0) }

        // Mouse-wheel (no momentum) arms the debounce timeout.
        probe.markScrollActivity(hasMomentum: false, momentumEnded: false)
        #expect(probe.isScrolling)
        for _ in 0..<10 {
            probe.recordTickSample(elapsedMs: 50)
        }

        await probe.awaitPendingScrollEnd()
        #expect(!probe.isScrolling)
        #expect(reports.count == 1)
        #expect(reports.first?.samples == 10)
    }
}

/// A clock whose `sleep` returns immediately, so the scroll-end debounce fires
/// deterministically in tests without real-time waits.
private struct ImmediateClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        // No-op: fire immediately.
    }
}
