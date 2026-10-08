import CMUXMobileCore
import Testing

@testable import CmuxMobileAnalytics

private struct ViewportTestConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}

@Suite struct MobileTerminalViewportReporterTests {
    @Test func repeatedLogicalCapacityIsMarkedAsLoopCandidate() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: ViewportTestConsent(isTelemetryEnabled: true),
            anonymousID: "viewport-test"
        )
        let reporter = MobileTerminalViewportReporter(emitter: emitter)

        for index in 0..<4 {
            reporter.ingest(DiagnosticEvent(
                code: .appFeatureAction,
                tNanos: UInt64(1_000_000_000 + index * 1_000_000_000),
                surface: 7,
                a: DiagnosticAppEventKind.terminalViewportReportPublished.rawValue,
                b: 80,
                c: 24,
                sequence: UInt64(index + 1)
            ))
        }

        await reporter.flush()
        let events = await uploader.uploadedEvents
        #expect(events.count == 4)
        #expect(events.allSatisfy { $0.name == MobileTerminalViewportReporter.eventName })
        #expect(events.first?.properties["columns"] == .int(80))
        #expect(events.first?.properties["rows"] == .int(24))
        #expect(events.first?.properties["same_capacity_reports"] == .int(1))
        #expect(events.last?.properties["same_capacity_reports"] == .int(4))
        #expect(events.last?.properties["loop_detected"] == .bool(true))
        #expect(events.last?.properties["repeat_window_ms"] == .int(3_000))
    }

    @Test func changingCapacityStartsANewEpisode() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: ViewportTestConsent(isTelemetryEnabled: true),
            anonymousID: "viewport-test"
        )
        let reporter = MobileTerminalViewportReporter(emitter: emitter)

        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 1_000_000_000,
            surface: 7,
            a: DiagnosticAppEventKind.terminalViewportReportPublished.rawValue,
            b: 80,
            c: 24,
            sequence: 1
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 2_000_000_000,
            surface: 7,
            a: DiagnosticAppEventKind.terminalViewportReportPublished.rawValue,
            b: 81,
            c: 24,
            sequence: 2
        ))

        await reporter.flush()
        let events = await uploader.uploadedEvents
        #expect(events.map { $0.properties["same_capacity_reports"] } == [.int(1), .int(1)])
        #expect(events.allSatisfy { $0.properties["loop_detected"] == .bool(false) })
    }

    @Test func invalidGeometryDoesNotReachAxiom() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: ViewportTestConsent(isTelemetryEnabled: true),
            anonymousID: "viewport-test"
        )
        let reporter = MobileTerminalViewportReporter(emitter: emitter)

        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 1,
            surface: 7,
            a: DiagnosticAppEventKind.terminalViewportReportPublished.rawValue,
            b: 2_000,
            c: 24,
            sequence: 1
        ))

        await reporter.flush()
        #expect(await uploader.uploadedEvents.isEmpty)
    }
}
