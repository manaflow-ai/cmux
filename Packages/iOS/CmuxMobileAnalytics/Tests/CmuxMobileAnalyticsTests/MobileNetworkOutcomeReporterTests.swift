import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileAnalytics

private struct NetworkOutcomeTestConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}

@Suite struct MobileNetworkOutcomeReporterTests {
    @Test func transportFailureCarriesStableOperationalDimensions() {
        let properties = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: 1,
            surface: 42,
            ms: 1_250,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.timedOut.rawValue,
            c: 7
        ))

        #expect(properties?["event_code"] == .int(27))
        #expect(properties?["event_name"] == .string("transportDialFailed"))
        #expect(properties?["outcome"] == .string("failure"))
        #expect(properties?["runtime_role"] == .string("mobileClient"))
        #expect(properties?["transport"] == .string("iroh"))
        #expect(properties?["failure"] == .string("timedOut"))
        #expect(properties?["duration_ms"] == .int(1_250))
        #expect(properties?["correlation_id"] == .int(42))
        #expect(properties?["detail_c"] == .int(7))
        #expect(properties?["user_usable"] == .bool(false))
    }

    @Test func usableRPCAndPathChangesAreDistinguished() {
        let ready = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .rpcReady,
            tNanos: 1,
            ms: 890,
            a: DiagnosticTransportKind.tailscale.rawValue
        ))
        let path = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .transportPathEvent,
            tNanos: 2,
            a: 3,
            b: DiagnosticPathKind.relay.rawValue,
            c: 9
        ))

        #expect(ready?["outcome"] == .string("success"))
        #expect(ready?["user_usable"] == .bool(true))
        #expect(ready?["transport"] == .string("tailscale"))
        #expect(path?["path"] == .string("relay"))
        #expect(path?["outcome"] == .string("state"))
    }

    @Test func expectedSessionCloseIsStateNotFailure() {
        let expectedClose = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .sessionClosed,
            tNanos: 1,
            a: DiagnosticTransportKind.iroh.rawValue
        ))

        #expect(expectedClose?["outcome"] == .string("state"))
        #expect(expectedClose?["failure"] == nil)
    }

    @Test func backendAndLatencyAppOutcomesAreIncludedButUIChurnIsIgnored() {
        let backend = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 1,
            ms: 400,
            a: DiagnosticAppEventKind.deviceRegistryLoadFailed.rawValue,
            b: DiagnosticFailureKind.timedOut.rawValue
        ))
        let latency = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 2,
            ms: 800,
            a: DiagnosticAppEventKind.terminalRenderLagDetected.rawValue,
            b: DiagnosticFailureKind.timedOut.rawValue
        ))
        let uiOnly = MobileNetworkOutcomeReporter.properties(for: DiagnosticEvent(
            code: .composerViewAppear,
            tNanos: 3
        ))

        #expect(backend?["operation"] == .string("deviceRegistryLoadFailed"))
        #expect(backend?["outcome"] == .string("failure"))
        #expect(latency?["operation"] == .string("terminalRenderLagDetected"))
        #expect(latency?["duration_ms"] == .int(800))
        #expect(uiOnly == nil)
    }

    @Test func ingestUsesDedicatedEventAndFlushesThroughTheEmitter() async {
        let uploader = RecordingAnalyticsUploader()
        let emitter = AnalyticsEmitter(
            uploader: uploader,
            consent: NetworkOutcomeTestConsent(isTelemetryEnabled: true),
            anonymousID: "local-install",
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        let reporter = MobileNetworkOutcomeReporter(emitter: emitter)

        reporter.ingest(DiagnosticEvent(
            code: .recoveryFailed,
            tNanos: 1,
            ms: 5_000,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.noRoute.rawValue
        ))
        reporter.ingest(DiagnosticEvent(code: .composerViewAppear, tNanos: 2))
        await reporter.flush()

        let events = await uploader.uploadedEvents
        #expect(events.count == 1)
        #expect(events.first?.name == MobileNetworkOutcomeReporter.eventName)
        #expect(events.first?.properties["event_name"] == .string("recoveryFailed"))
        #expect(events.first?.properties["failure"] == .string("noRoute"))
    }
}
