import Foundation
import Testing
@testable import CMUXMobileCore

@Suite
struct CmxIrohConnectionCheckReportTests {
    @Test
    func mobileReportsReadyForAnAuthenticatedPrivateVPNPath() {
        let report = CmxIrohConnectionCheckReport(
            role: .mobileClient,
            snapshot: snapshot(
                runtimeStatus: .privateNetwork(displayName: ""),
                selectedPath: .privateNetwork,
                hasMac: true
            ),
            diagnostics: .empty,
            relayReachability: .reachable,
            macDiscovery: .found
        )

        #expect(report.isReady)
        #expect(report.recommendation == .none)
        #expect(report.stages.allSatisfy { $0.status == .passed })
    }

    @Test
    func relayFailureExplainsCorporateNetworkAllowlisting() {
        let report = CmxIrohConnectionCheckReport(
            role: .mobileClient,
            snapshot: snapshot(runtimeStatus: .active, hasMac: true),
            diagnostics: diagnosticFailure(.timedOut),
            relayReachability: .unreachable,
            macDiscovery: .found
        )

        #expect(!report.isReady)
        #expect(report.recommendation == .allowRelayTraffic)
        #expect(report.stages.first { $0.kind == .relayReachability }?.status == .failed)
    }

    @Test
    func relayConfigurationFailureTakesPriorityOverGenericAccountAdvice() {
        let brokenRelaySnapshot = CmxIrohSettingsSnapshot(
            runtimeStatus: .degraded,
            preference: .automatic,
            managedRelays: [],
            customRelays: [],
            policySource: .server,
            failureDescription: "redacted relay configuration failure"
        )
        let report = CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: brokenRelaySnapshot,
            diagnostics: .empty,
            relayReachability: .unavailable
        )

        #expect(report.recommendation == .reviewRelaySettings)
    }

    @Test
    func missingMacIsDistinguishedFromAReachableRelay() {
        let report = CmxIrohConnectionCheckReport(
            role: .mobileClient,
            snapshot: snapshot(runtimeStatus: .active),
            diagnostics: .empty,
            relayReachability: .reachable,
            macDiscovery: .missing
        )

        #expect(report.recommendation == .openMacApp)
        #expect(report.stages.first { $0.kind == .macDiscovery }?.status == .failed)
    }

    @Test
    func unavailableRelayProbeFailsClosedWhileNoRelayConfigurationIsOptional() {
        let unavailable = CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot(runtimeStatus: .active),
            diagnostics: .empty,
            relayReachability: .unavailable
        )
        let notConfigured = CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot(runtimeStatus: .active),
            diagnostics: .empty,
            relayReachability: .notConfigured
        )

        #expect(!unavailable.isReady)
        #expect(
            unavailable.stages.first { $0.kind == .relayReachability }?.status == .failed
        )
        #expect(unavailable.recommendation == .retry)
        #expect(notConfigured.isReady)
        #expect(
            notConfigured.stages.first { $0.kind == .relayReachability }?.status
                == .notApplicable
        )
    }

    @Test
    func administrativelyDisabledRelayFailsSessionWithRetryNotITAdvice() {
        // Direct Only transport mode maps to a not-configured relay at the
        // call sites: the relay stage reads Not Needed, and a dead direct
        // path recommends retrying instead of contacting corporate IT.
        let report = CmxIrohConnectionCheckReport(
            role: .mobileClient,
            snapshot: snapshot(runtimeStatus: .active, hasMac: true),
            diagnostics: .empty,
            relayReachability: .notConfigured,
            macDiscovery: .found
        )

        #expect(
            report.stages.first { $0.kind == .relayReachability }?.status == .notApplicable
        )
        #expect(report.stages.first { $0.kind == .secureSession }?.status == .failed)
        #expect(report.recommendation == .retry)
    }

    @Test
    func unavailableProbeNeverAdvisesCorporateAllowlisting() {
        // An unavailable probe means the runtime was inactive or its path
        // hints were unreadable, not that a relay was probed and blocked.
        let inactiveRuntime = CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot(runtimeStatus: .inactive),
            diagnostics: .empty,
            relayReachability: .unavailable
        )

        #expect(inactiveRuntime.recommendation == .refreshAccount)
    }

    @Test
    func relayAllowlistOriginsRejectCredentialsAndNonRootURLs() {
        #expect([
            "https://relay.example.test/",
            "https://relay.example.test",
            "https://relay.example.test:443",
            "https://user:secret@relay.example.test",
            "https://relay.example.test/private",
            "https://relay.example.test?token=secret",
            "http://relay.example.test",
        ].cmxIrohCanonicalRelayOrigins() == [
            "https://relay.example.test",
            "https://relay.example.test:443",
        ])
    }

    @Test
    func macReadinessDoesNotRequireAnActivePhoneSession() {
        let report = CmxIrohConnectionCheckReport(
            role: .macHost,
            snapshot: snapshot(runtimeStatus: .active),
            diagnostics: .empty,
            relayReachability: .reachable
        )

        #expect(report.isReady)
        #expect(report.stages.first { $0.kind == .secureSession }?.status == .notApplicable)
    }

    private func snapshot(
        runtimeStatus: CmxIrohSettingsSnapshot.RuntimeStatus,
        selectedPath: CmxIrohSelectedTransportPath = .unavailable,
        hasMac: Bool = false
    ) -> CmxIrohSettingsSnapshot {
        CmxIrohSettingsSnapshot(
            runtimeStatus: runtimeStatus,
            selectedTransportPath: selectedPath,
            preference: .automatic,
            managedRelays: [],
            customRelays: [],
            privateNetworkMacs: hasMac
                ? [.init(macDeviceID: "mac", displayName: "Mac")]
                : [],
            policySource: .server
        )
    }

    private func diagnosticFailure(_ kind: DiagnosticFailureKind) -> DiagnosticReport {
        DiagnosticReport(
            role: .mobileClient,
            generatedAt: Date(timeIntervalSince1970: 1),
            anchorWallNanos: 1,
            anchorMonotonicNanos: 1,
            events: [
                DiagnosticEvent(
                    code: .transportDialFailed,
                    tNanos: 2,
                    a: Int(DiagnosticTransportKind.iroh.rawValue),
                    b: Int(kind.rawValue)
                )
            ]
        )
    }
}
