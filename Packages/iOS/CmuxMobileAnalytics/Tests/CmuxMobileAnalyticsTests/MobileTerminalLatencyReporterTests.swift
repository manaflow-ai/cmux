import Foundation
import Testing

import CMUXMobileCore
@testable import CmuxMobileAnalytics

private final class LatencyTestClock: @unchecked Sendable {
    var value: UInt64 = 0
}

@Suite struct MobileTerminalLatencyReporterTests {
    @Test @MainActor func flushEmitsCorrelatedWindowMetrics() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: FixedLatencyConsent(isTelemetryEnabled: true),
            anonymousID: "latency-test"
        )
        let clock = LatencyTestClock()
        let reporter = MobileTerminalLatencyReporter(
            emitter: emitter,
            window: .seconds(10),
            now: { clock.value }
        )

        let sequence = reporter.inputStarted(surfaceID: "terminal", byteCount: 3)
        reporter.inputSent(surfaceID: "terminal", sequence: sequence)
        clock.value = 5_000_000
        reporter.outputReceived(
            surfaceID: "terminal",
            appliedInputSequence: sequence,
            byteCount: 4,
            queueDepth: 2
        )
        clock.value = 10_000_000
        reporter.outputPresented(surfaceID: "terminal")
        await reporter.flush()

        let event = await uploader.uploadedEvents.first { $0.name == MobileTerminalLatencyReporter.windowEventName }
        #expect(event?.properties["input_count"] == .int(1))
        #expect(event?.properties["correlated_output_count"] == .int(1))
        #expect(event?.properties["input_to_output_p50_ms"] == .int(5))
        #expect(event?.properties["input_to_visible_p50_ms"] == .int(10))
        #expect(event?.properties["render_p50_ms"] == .int(5))
        #expect(event?.properties["max_queue_depth"] == .int(2))
    }
}

private struct FixedLatencyConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}
