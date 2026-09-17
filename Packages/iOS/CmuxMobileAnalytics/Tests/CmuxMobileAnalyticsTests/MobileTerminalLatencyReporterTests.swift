import Foundation
import Testing

import CMUXMobileCore
@testable import CmuxMobileAnalytics

@MainActor private final class LatencyTestClock {
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
        reporter.outputApplied(surfaceID: "terminal")
        reporter.framePresented(surfaceID: "terminal", inputSequence: sequence, receivedAtNanos: 5_000_000)
        await reporter.flush()

        let event = await uploader.uploadedEvents.first { $0.name == MobileTerminalLatencyReporter.windowEventName }
        #expect(event?.properties["input_count"] == .int(1))
        #expect(event?.properties["correlated_output_count"] == .int(1))
        #expect(event?.properties["input_to_output_p50_ms"] == .int(8))
        #expect(event?.properties["input_to_visible_p50_ms"] == .int(16))
        #expect(event?.properties["render_p50_ms"] == .int(8))
        #expect(event?.properties["max_queue_depth"] == .int(2))
    }
    @Test @MainActor func repeatedWatermarksDoNotCreateFalseSpikes() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(uploader: uploader, consent: FixedLatencyConsent(isTelemetryEnabled: true), anonymousID: "latency-test")
        let clock = LatencyTestClock()
        let reporter = MobileTerminalLatencyReporter(emitter: emitter, now: { clock.value })
        let sequence = reporter.inputStarted(surfaceID: "s", byteCount: 1)
        clock.value = 10_000_000
        reporter.outputReceived(surfaceID: "s", appliedInputSequence: sequence, byteCount: 1, queueDepth: 0)
        clock.value = 120_000_000_000
        reporter.outputReceived(surfaceID: "s", appliedInputSequence: sequence, byteCount: 1, queueDepth: 0)
        await reporter.flush()
        let events = await uploader.uploadedEvents
        #expect(events.count == 1)
        #expect(events[0].properties["correlated_output_count"] == .int(1))
        #expect(events[0].properties["input_to_output_p99_ms"] == .int(16))
    }

    @Test @MainActor func cumulativeWatermarkIncludesEarlierWaitingInputs() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(uploader: uploader, consent: FixedLatencyConsent(isTelemetryEnabled: true), anonymousID: "latency-test")
        let clock = LatencyTestClock()
        let reporter = MobileTerminalLatencyReporter(emitter: emitter, now: { clock.value })
        _ = reporter.inputStarted(surfaceID: "s", byteCount: 1)
        clock.value = 2_000_000_000
        let latest = reporter.inputStarted(surfaceID: "s", byteCount: 1)
        clock.value = 2_010_000_000
        reporter.outputReceived(surfaceID: "s", appliedInputSequence: latest, byteCount: 1, queueDepth: 0)
        clock.value = 2_020_000_000
        reporter.framePresented(surfaceID: "s", inputSequence: latest, receivedAtNanos: 2_010_000_000)
        await reporter.flush()
        let event = await uploader.uploadedEvents.first { $0.name == MobileTerminalLatencyReporter.windowEventName }
        #expect(event?.properties["correlated_output_count"] == .int(2))
        #expect(event?.properties["input_to_visible_p95_ms"] == .int(2048))
    }

    @Test @MainActor func unknownAndFailedMarkersRemainUncorrelated() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(uploader: uploader, consent: FixedLatencyConsent(isTelemetryEnabled: true), anonymousID: "latency-test")
        let reporter = MobileTerminalLatencyReporter(emitter: emitter)
        let sequence = reporter.inputStarted(surfaceID: "s", byteCount: 1)
        reporter.inputFailed(surfaceID: "s", sequence: sequence)
        reporter.outputReceived(surfaceID: "s", appliedInputSequence: sequence, byteCount: 1, queueDepth: 0)
        reporter.outputReceived(surfaceID: "s", appliedInputSequence: sequence + 1, byteCount: 1, queueDepth: 0)
        await reporter.flush()
        let event = await uploader.uploadedEvents.first
        #expect(event?.properties["correlated_output_count"] == .int(0))
        #expect(event?.properties["input_failed_count"] == .int(1))
        #expect(event?.properties["render_histogram"] == .string("[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]"))
    }

    @Test @MainActor func queueAckIsNotAPresentationAndRepeatedDrawIsCountedOnce() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(uploader: uploader, consent: FixedLatencyConsent(isTelemetryEnabled: true), anonymousID: "latency-test")
        let clock = LatencyTestClock()
        let reporter = MobileTerminalLatencyReporter(emitter: emitter, now: { clock.value })
        clock.value = 1_000_000
        reporter.outputReceived(surfaceID: "s", appliedInputSequence: nil, byteCount: 1, queueDepth: 1)
        reporter.outputApplied(surfaceID: "s")
        await reporter.flush()
        #expect(await uploader.uploadedEvents.first?.properties["presented_count"] == .int(0))
        clock.value = 10_000_000
        reporter.framePresented(surfaceID: "s", inputSequence: nil, receivedAtNanos: 1_000_000)
        clock.value = 15_000_000
        reporter.framePresented(surfaceID: "s", inputSequence: nil, receivedAtNanos: 1_000_000)
        await reporter.flush()
        #expect(await uploader.uploadedEvents.last?.properties["presented_count"] == .int(1))
    }

}

private struct FixedLatencyConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}
