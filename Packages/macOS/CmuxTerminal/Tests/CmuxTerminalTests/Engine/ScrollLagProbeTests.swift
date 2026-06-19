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
}
