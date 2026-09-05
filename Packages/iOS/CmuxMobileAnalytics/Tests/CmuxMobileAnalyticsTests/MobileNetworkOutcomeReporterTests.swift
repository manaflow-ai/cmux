import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileAnalytics

private struct NetworkOutcomeTestConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}

@Suite struct MobileNetworkOutcomeReporterTests {
    @Test func transportDialCompletionEmitsLatencyOnly() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: NetworkOutcomeTestConsent(isTelemetryEnabled: true),
            anonymousID: "local-install"
        )
        let reporter = MobileNetworkOutcomeReporter(emitter: emitter)

        reporter.ingest(DiagnosticEvent(
            code: .transportDialStarted,
            tNanos: 1_000_000_000,
            a: DiagnosticTransportKind.iroh.rawValue,
            c: 7
        ))
        reporter.ingest(DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: 2_250_000_000,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.timedOut.rawValue,
            c: 7
        ))
        await reporter.flush()

        let event = await uploader.uploadedEvents.first
        #expect(event?.name == "ios_connectivity_latency")
        #expect(event?.properties["phase"] == .string("transport_dial"))
        #expect(event?.properties["outcome"] == .string("timeout"))
        #expect(event?.properties["duration_ms"] == .int(1_250))
        #expect(event?.properties["transport"] == .string("iroh"))
        #expect(event?.properties["failure"] == .string("timedOut"))
        #expect(event?.properties["event_code"] == nil)
    }

    @Test func recoveryUsesMonotonicElapsedTime() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: NetworkOutcomeTestConsent(isTelemetryEnabled: true),
            anonymousID: "local-install"
        )
        let reporter = MobileNetworkOutcomeReporter(emitter: emitter)

        reporter.ingest(DiagnosticEvent(code: .recoveryStarted, tNanos: 1_000_000_000, surface: 9))
        reporter.ingest(DiagnosticEvent(code: .recoverySucceeded, tNanos: 4_000_000_000, surface: 9))
        await reporter.flush()

        let event = await uploader.uploadedEvents.first
        #expect(event?.properties["phase"] == .string("recovery"))
        #expect(event?.properties["duration_ms"] == .int(3_000))
        #expect(event?.properties["outcome"] == .string("success"))
        #expect(event?.properties["user_usable"] == .bool(true))
    }

    @Test func pairingAndRpcReadyEachEmitTerminalLatency() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: NetworkOutcomeTestConsent(isTelemetryEnabled: true),
            anonymousID: "local-install"
        )
        let reporter = MobileNetworkOutcomeReporter(emitter: emitter)

        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 1_000_000_000, surface: 4))
        reporter.ingest(DiagnosticEvent(code: .pairOk, tNanos: 2_000_000_000, surface: 4))
        reporter.ingest(DiagnosticEvent(code: .rpcReady, tNanos: 3_000_000_000, surface: 4))
        await reporter.flush()

        let values = await uploader.uploadedEvents
        #expect(values.map { $0.properties["phase"] } == [.string("pairing"), .string("rpc_ready")])
        #expect(values[1].properties["duration_ms"] == .int(1_000))
        #expect(values[1].properties["user_usable"] == .bool(true))
    }

    @Test func rpcFailureEmitsNonUsableReadinessLatency() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: NetworkOutcomeTestConsent(isTelemetryEnabled: true),
            anonymousID: "local-install"
        )
        let reporter = MobileNetworkOutcomeReporter(emitter: emitter)

        reporter.ingest(DiagnosticEvent(code: .connect, tNanos: 1_000_000_000, surface: 8))
        reporter.ingest(DiagnosticEvent(code: .pairOk, tNanos: 2_000_000_000, surface: 8))
        reporter.ingest(DiagnosticEvent(
            code: .rpcFailed,
            tNanos: 3_000_000_000,
            surface: 8,
            b: DiagnosticFailureKind.timedOut.rawValue
        ))
        await reporter.flush()

        let values = await uploader.uploadedEvents
        #expect(values.last?.properties["phase"] == .string("rpc_ready"))
        #expect(values.last?.properties["outcome"] == .string("timeout"))
        #expect(values.last?.properties["user_usable"] == .bool(false))
    }

    @Test func rpcReadyUsesExistingMeasuredDuration() {
        let properties = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .rpcReady,
            tNanos: 1,
            ms: 890,
            a: DiagnosticTransportKind.tailscale.rawValue
        ))

        #expect(properties?["phase"] == .string("rpc_ready"))
        #expect(properties?["duration_ms"] == .int(890))
        #expect(properties?["outcome"] == .string("success"))
        #expect(properties?["user_usable"] == .bool(true))
        #expect(properties?["transport"] == .string("tailscale"))
    }

    @Test func endpointFailureComputesDurationAndIgnoresUiChurn() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: NetworkOutcomeTestConsent(isTelemetryEnabled: true),
            anonymousID: "local-install"
        )
        let reporter = MobileNetworkOutcomeReporter(emitter: emitter)
        reporter.ingest(DiagnosticEvent(code: .endpointStarting, tNanos: 10_000_000_000))
        reporter.ingest(DiagnosticEvent(
            code: .endpointFailed,
            tNanos: 11_500_000_000,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.endpointUnavailable.rawValue
        ))
        reporter.ingest(DiagnosticEvent(code: .composerViewAppear, tNanos: 12_000_000_000))
        await reporter.flush()

        let values = await uploader.uploadedEvents
        #expect(values.count == 1)
        #expect(values.first?.properties["phase"] == .string("endpoint_start"))
        #expect(values.first?.properties["duration_ms"] == .int(1_500))
    }

    @Test func ordinaryDiagnosticEventIsIgnored() {
        let properties = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .composerViewAppear,
            tNanos: 3
        ))
        #expect(properties == nil)
    }
}
