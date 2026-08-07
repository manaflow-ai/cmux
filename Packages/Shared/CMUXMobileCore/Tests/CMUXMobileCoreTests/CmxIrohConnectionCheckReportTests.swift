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
            relayReachability: .reachable
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
            relayReachability: .unreachable
        )

        #expect(!report.isReady)
        #expect(report.recommendation == .allowRelayTraffic)
        #expect(report.stages.first { $0.kind == .relayReachability }?.status == .failed)
    }

    @Test
    func missingMacIsDistinguishedFromAReachableRelay() {
        let report = CmxIrohConnectionCheckReport(
            role: .mobileClient,
            snapshot: snapshot(runtimeStatus: .active),
            diagnostics: .empty,
            relayReachability: .reachable
        )

        #expect(report.recommendation == .openMacApp)
        #expect(report.stages.first { $0.kind == .macDiscovery }?.status == .failed)
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
            privateNetworkMacs: hasMac ? [.init(id: "mac", displayName: "Mac")] : [],
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
