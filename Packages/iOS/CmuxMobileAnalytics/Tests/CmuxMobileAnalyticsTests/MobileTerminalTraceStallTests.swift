import CMUXMobileCore
import Testing

@testable import CmuxMobileAnalytics

private struct StallTestConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}

/// A replay that never settles is the blank-terminal stall. These cover the
/// emission path that makes it visible at all.
@Suite("Terminal replay stall reporting")
struct MobileTerminalTraceStallTests {
    private func makeReporter() -> (MobileTerminalTraceReporter, RecordingAnalyticsUploader) {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: StallTestConsent(isTelemetryEnabled: true),
            anonymousID: "local-install"
        )
        return (MobileTerminalTraceReporter(emitter: emitter), uploader)
    }

    private func event(
        _ phase: DiagnosticTerminalTracePhase,
        at tNanos: UInt64,
        trace: DiagnosticTerminalTraceID,
        ms: UInt32? = nil,
        c: Int? = nil
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            code: .terminalTrace,
            tNanos: tNanos,
            ms: ms,
            a: DiagnosticTerminalTraceOperation.replay.rawValue,
            b: phase.rawValue,
            c: c,
            traceID: trace.rawValue
        )
    }

    @Test func aReplayThatNeverSettlesStillReportsToAxiom() async {
        let (reporter, uploader) = makeReporter()
        let trace = DiagnosticTerminalTraceID(rawValue: 0xB1A4)!
        let context = MobileTerminalReplayTraceContext(
            trigger: .outputReset, surfaceIsBlank: true, barrierActive: true, attempt: 0
        )
        reporter.ingest(event(.started, at: 1_000_000_000, trace: trace, c: context.encoded))
        reporter.ingest(event(.stalled, at: 3_000_000_000, trace: trace, ms: 2_000, c: context.encoded))
        reporter.ingest(event(.stalled, at: 31_000_000_000, trace: trace, ms: 30_000, c: context.encoded))
        await reporter.flush()

        let values = await uploader.uploadedEvents
        #expect(values.count == 2)
        #expect(values.allSatisfy { $0.properties["outcome"] == .string("stalled") })
        #expect(values.allSatisfy { $0.properties["terminal_phase"] == .string("stalled") })
        #expect(values.first?.properties["duration_ms"] == .int(2_000))
        #expect(values.last?.properties["duration_ms"] == .int(30_000))
        // The fields that separate a blank terminal from merely stale text.
        #expect(values.first?.properties["surface_blank"] == .bool(true))
        #expect(values.first?.properties["barrier_active"] == .bool(true))
        #expect(values.first?.properties["replay_trigger"] == .string("outputReset"))
        #expect(values.first?.properties["replay_attempt"] == .int(0))
    }

    /// A stall report must not consume the pending start: the settled phase
    /// still has to report, and its duration must still span from `started`.
    @Test func stallReportDoesNotSwallowTheSettledPhase() async {
        let (reporter, uploader) = makeReporter()
        let trace = DiagnosticTerminalTraceID(rawValue: 0xB1A5)!
        let context = MobileTerminalReplayTraceContext(
            trigger: .coldAttach, surfaceIsBlank: true, barrierActive: false, attempt: 2
        )
        reporter.ingest(event(.started, at: 1_000_000_000, trace: trace, c: context.encoded))
        reporter.ingest(event(.stalled, at: 3_000_000_000, trace: trace, ms: 2_000, c: context.encoded))
        reporter.ingest(event(.failed, at: 31_000_000_000, trace: trace))
        await reporter.flush()

        let values = await uploader.uploadedEvents
        #expect(values.count == 2)
        #expect(values.last?.properties["outcome"] == .string("failure"))
        #expect(values.last?.properties["duration_ms"] == .int(30_000))
        // The context recorded at `started` survives onto the settled row.
        #expect(values.last?.properties["replay_trigger"] == .string("coldAttach"))
        #expect(values.last?.properties["surface_blank"] == .bool(true))
        #expect(values.last?.properties["replay_attempt"] == .int(2))
    }

    /// A fast successful replay stays below the slow threshold and must not
    /// gain a row just because the context fields now exist.
    @Test func fastSuccessfulReplayStillEmitsNothing() async {
        let (reporter, uploader) = makeReporter()
        let trace = DiagnosticTerminalTraceID(rawValue: 0xB1A6)!
        let context = MobileTerminalReplayTraceContext(
            trigger: .viewportTransition, surfaceIsBlank: false, barrierActive: true, attempt: 0
        )
        reporter.ingest(event(.started, at: 1_000_000_000, trace: trace, c: context.encoded))
        reporter.ingest(event(.applied, at: 1_300_000_000, trace: trace))
        await reporter.flush()

        #expect((await uploader.uploadedEvents).isEmpty)
    }

    @Test func stallWithoutAnElapsedMagnitudeIsDropped() async {
        let (reporter, uploader) = makeReporter()
        let trace = DiagnosticTerminalTraceID(rawValue: 0xB1A7)!
        reporter.ingest(event(.started, at: 1_000_000_000, trace: trace))
        reporter.ingest(event(.stalled, at: 3_000_000_000, trace: trace))
        await reporter.flush()

        #expect((await uploader.uploadedEvents).isEmpty)
    }
}
