import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileAnalytics

private struct InitialConnectionTestConsent: AnalyticsConsentProviding {
    let isTelemetryEnabled: Bool
}

@Suite struct MobileInitialConnectionReporterTests {
    @Test func coldOpenWaitsForRpcAndMountedTerminal() async {
        let (product, operational, productUploader, operationalUploader) = makeEmitters()
        let reporter = MobileInitialConnectionReporter(
            productEmitter: product,
            operationalEmitter: operational
        )

        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 1_000_000_000,
            a: DiagnosticAppEventKind.appForegrounded.rawValue
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 2_000_000_000,
            a: DiagnosticAppEventKind.connectionStateChanged.rawValue,
            c: 1
        ))
        reporter.ingest(DiagnosticEvent(
            code: .rpcReady,
            tNanos: 3_000_000_000,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 4_000_000_000,
            a: DiagnosticAppEventKind.terminalMounted.rawValue
        ))
        await reporter.flush()

        let productEvent = await productUploader.uploadedEvents.first
        let operationalEvent = await operationalUploader.uploadedEvents.first
        #expect(productEvent?.name == "ios_initial_connection")
        #expect(productEvent?.properties["population"] == .string("cold_open"))
        #expect(productEvent?.properties["duration_ms"] == .int(3_000))
        #expect(productEvent?.properties["outcome"] == .string("success"))
        #expect(productEvent?.properties["user_usable"] == .bool(true))
        #expect(productEvent?.properties["attempt_id"] != nil)
        #expect(operationalEvent?.name == "ios_connectivity_latency")
        #expect(operationalEvent?.properties["phase"] == .string("initial_connect"))
        #expect(operationalEvent?.properties["transport"] == .string("iroh"))
    }

    @Test func pairingRetryProducesOnePairingRequiredResult() async {
        let (product, operational, productUploader, operationalUploader) = makeEmitters()
        let reporter = MobileInitialConnectionReporter(
            productEmitter: product,
            operationalEmitter: operational
        )

        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 1_000_000_000,
            a: DiagnosticAppEventKind.appForegrounded.rawValue
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 2_000_000_000,
            a: DiagnosticAppEventKind.pairingStarted.rawValue
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 3_000_000_000,
            a: DiagnosticAppEventKind.pairingFailed.rawValue,
            b: DiagnosticFailureKind.timedOut.rawValue
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 4_000_000_000,
            a: DiagnosticAppEventKind.pairingStarted.rawValue
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 5_000_000_000,
            a: DiagnosticAppEventKind.connectionStateChanged.rawValue,
            c: 1
        ))
        reporter.ingest(DiagnosticEvent(
            code: .rpcReady,
            tNanos: 6_000_000_000,
            a: DiagnosticTransportKind.tailscale.rawValue
        ))
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 7_000_000_000,
            a: DiagnosticAppEventKind.terminalMounted.rawValue
        ))
        await reporter.flush()

        let productEvents = await productUploader.uploadedEvents
        let operationalEvents = await operationalUploader.uploadedEvents
        #expect(productEvents.count == 1)
        #expect(operationalEvents.count == 1)
        #expect(productEvents[0].properties["population"] == .string("pairing_required"))
        #expect(productEvents[0].properties["duration_ms"] == .int(6_000))
        #expect(productEvents[0].properties["transport"] == .string("tailscale"))
    }

    @Test func reconnectAndTimeoutAreBoundedOutcomes() async throws {
        let (product, operational, productUploader, operationalUploader) = makeEmitters()
        let reporter = MobileInitialConnectionReporter(
            productEmitter: product,
            operationalEmitter: operational,
            timeout: .milliseconds(1)
        )

        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 1_000_000_000,
            a: DiagnosticAppEventKind.appForegrounded.rawValue
        ))
        try await Task.sleep(for: .milliseconds(20))
        await reporter.flush()

        let timeout = await productUploader.uploadedEvents.first
        #expect(timeout?.properties["outcome"] == .string("timeout"))
        #expect(timeout?.properties["population"] == .string("cold_open"))
        #expect(timeout?.properties["user_usable"] == .bool(false))

        let reconnectReporter = MobileInitialConnectionReporter(
            productEmitter: product,
            operationalEmitter: operational
        )
        reconnectReporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 2_000_000_000,
            a: DiagnosticAppEventKind.connectionStateChanged.rawValue,
            c: 0
        ))
        reconnectReporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 3_000_000_000,
            a: DiagnosticAppEventKind.reconnectStarted.rawValue
        ))
        reconnectReporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 4_000_000_000,
            a: DiagnosticAppEventKind.connectionStateChanged.rawValue,
            c: 1
        ))
        reconnectReporter.ingest(DiagnosticEvent(
            code: .rpcReady,
            tNanos: 5_000_000_000
        ))
        reconnectReporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 6_000_000_000,
            a: DiagnosticAppEventKind.terminalMounted.rawValue
        ))
        await reconnectReporter.flush()

        let productEvents = await productUploader.uploadedEvents
        let operationalEvents = await operationalUploader.uploadedEvents
        #expect(productEvents.count == 2)
        #expect(operationalEvents.count == 2)
        #expect(productEvents[1].properties["population"] == .string("reconnect"))
        #expect(productEvents[1].properties["duration_ms"] == .int(3_000))
    }

    @Test func telemetryOptOutEmitsNothing() async {
        let productUploader = RecordingAnalyticsUploader()
        let operationalUploader = RecordingAnalyticsUploader()
        let product = AnalyticsEmitter(
            uploader: productUploader,
            consent: InitialConnectionTestConsent(isTelemetryEnabled: false),
            anonymousID: "initial-connection-test"
        )
        let operational = AnalyticsEmitter(
            uploader: operationalUploader,
            consent: InitialConnectionTestConsent(isTelemetryEnabled: false),
            anonymousID: "initial-connection-test"
        )
        let reporter = MobileInitialConnectionReporter(
            productEmitter: product,
            operationalEmitter: operational,
            timeout: .milliseconds(1)
        )
        reporter.ingest(DiagnosticEvent(
            code: .appFeatureAction,
            tNanos: 1,
            a: DiagnosticAppEventKind.appForegrounded.rawValue
        ))
        await reporter.flush()

        #expect(await productUploader.uploadedEvents.isEmpty)
        #expect(await operationalUploader.uploadedEvents.isEmpty)
    }
}

private func makeEmitters() -> (
    AnalyticsEmitter,
    AnalyticsEmitter,
    RecordingAnalyticsUploader,
    RecordingAnalyticsUploader
) {
    let productUploader = RecordingAnalyticsUploader()
    let operationalUploader = RecordingAnalyticsUploader()
    let consent = InitialConnectionTestConsent(isTelemetryEnabled: true)
    return (
        AnalyticsEmitter(
            uploader: productUploader,
            consent: consent,
            anonymousID: "initial-connection-test"
        ),
        AnalyticsEmitter(
            uploader: operationalUploader,
            consent: consent,
            anonymousID: "initial-connection-test"
        ),
        productUploader,
        operationalUploader
    )
}
