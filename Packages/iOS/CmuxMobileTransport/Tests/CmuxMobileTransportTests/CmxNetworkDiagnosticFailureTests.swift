import CMUXMobileCore
import Testing

@testable import CmuxMobileTransport

@Suite struct CmxNetworkDiagnosticFailureTests {
    @Test func mapsNetworkFailuresWithoutExportingAssociatedText() {
        #expect(
            DiagnosticFailureKind.classify(
                CmxNetworkByteTransportError.connectionFailed(
                    "private hostname and system error",
                    .dnsFailed
                )
            ) == .dnsFailed
        )
        #expect(
            DiagnosticFailureKind.classify(
                CmxNetworkByteTransportError.receiveFailed("private remote address")
            ) == .connectionClosed
        )
        #expect(
            DiagnosticFailureKind.classify(
                CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            ) == .authorizationFailed
        )
    }
}
