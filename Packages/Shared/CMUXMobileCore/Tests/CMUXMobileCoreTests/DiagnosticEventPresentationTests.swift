import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct DiagnosticEventPresentationTests {
    /// Case names are shipped telemetry vocabulary (Sentry grouping keys), so a
    /// rename is a breaking change this test makes visible.
    @Test func pinsEventCodeNames() {
        #expect(DiagnosticEventPresentation.name(DiagnosticEventCode.transportDialFailed) == "transportDialFailed")
        #expect(DiagnosticEventPresentation.name(DiagnosticEventCode.endpointFailed) == "endpointFailed")
        #expect(DiagnosticEventPresentation.name(DiagnosticEventCode.pairFail) == "pairFail")
        #expect(DiagnosticEventPresentation.name(DiagnosticEventCode.sessionClosed) == "sessionClosed")
        #expect(DiagnosticEventPresentation.name(DiagnosticEventCode.retryScheduled) == "retryScheduled")
        #expect(DiagnosticEventPresentation.name(DiagnosticEventCode.hostAuthenticationFailed) == "hostAuthenticationFailed")
    }

    @Test func pinsTaxonomyNames() {
        #expect(DiagnosticEventPresentation.name(DiagnosticFailureKind.policyUnavailable) == "policyUnavailable")
        #expect(DiagnosticEventPresentation.name(DiagnosticFailureKind.identityMismatch) == "identityMismatch")
        #expect(DiagnosticEventPresentation.name(DiagnosticFailureKind.authorizationFailed) == "authorizationFailed")
        #expect(DiagnosticEventPresentation.name(DiagnosticTransportKind.iroh) == "iroh")
        #expect(DiagnosticEventPresentation.name(DiagnosticPathKind.relay) == "relay")
        #expect(DiagnosticEventPresentation.name(DiagnosticRuntimeRole.mobileClient) == "mobileClient")
        #expect(DiagnosticEventPresentation.name(DiagnosticAppLifecyclePhase.background) == "background")
    }

    @Test func describesDialFailure() {
        let event = DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: 1,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.policyUnavailable.rawValue,
            c: 42
        )
        let described = DiagnosticEventPresentation.describe(event)
        #expect(described.name == "transportDialFailed")
        #expect(described.fields == [
            .init(key: "transport", value: "iroh"),
            .init(key: "failure", value: "policyUnavailable"),
            .init(key: "attempt_id", value: "42"),
        ])
    }

    @Test func describesRetryDelayAndCloseAttribution() {
        let retry = DiagnosticEventPresentation.describe(
            DiagnosticEvent(code: .retryScheduled, tNanos: 1, ms: 32_331)
        )
        #expect(retry.fields == [.init(key: "delay_ms", value: "32331")])

        let close = DiagnosticEventPresentation.describe(
            DiagnosticEvent(
                code: .transportCloseAttribution,
                tNanos: 1,
                ms: 7,
                a: 3,
                b: DiagnosticFailureKind.transportIdleTimedOut.rawValue,
                c: 9
            )
        )
        #expect(close.fields == [
            .init(key: "app_error_code", value: "7"),
            .init(key: "initiator", value: "timedOut"),
            .init(key: "failure", value: "transportIdleTimedOut"),
            .init(key: "session_id", value: "9"),
        ])
    }

    @Test func describesLifecycleAndReachability() {
        let phase = DiagnosticEventPresentation.describe(
            DiagnosticEvent(code: .appLifecycleChanged, tNanos: 1, a: DiagnosticAppLifecyclePhase.background.rawValue)
        )
        #expect(phase.fields == [.init(key: "phase", value: "background")])

        let reachability = DiagnosticEventPresentation.describe(
            DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0)
        )
        #expect(reachability.fields == [.init(key: "reachable", value: "false")])
    }

    @Test func unknownRawValuesFallBackToIntegers() {
        let described = DiagnosticEventPresentation.describe(
            DiagnosticEvent(code: .transportDialFailed, tNanos: 1, a: 999, b: 998)
        )
        #expect(described.fields == [
            .init(key: "transport", value: "999"),
            .init(key: "failure", value: "998"),
        ])
    }

    @Test func extractsFailureAndTransportKinds() {
        let event = DiagnosticEvent(
            code: .endpointFailed,
            tNanos: 1,
            b: DiagnosticFailureKind.identityMismatch.rawValue
        )
        #expect(DiagnosticEventPresentation.failureKind(of: event) == .identityMismatch)
        #expect(DiagnosticEventPresentation.transportKind(of: event) == nil)

        let success = DiagnosticEvent(code: .rpcReady, tNanos: 1, b: 3)
        #expect(DiagnosticEventPresentation.failureKind(of: success) == nil)
    }
}
