import IrohLib
import Testing

@testable import CmuxIrohTransport

@Suite struct CmxIrohRelayDiagnosticObserverTests {
    @Test(arguments: [
        (RelayFailureKind.unknownIssuer, "UnknownIssuer"),
        (.hostnameMismatch, "HostnameMismatch"),
        (.certificateExpired, "CertificateExpired"),
        (.certificateNotYetValid, "CertificateNotYetValid"),
        (.certificateRevoked, "CertificateRevoked"),
        (.systemTrustFailed, "SystemTrustFailed"),
        (.tlsFailed, "TLSFailed"),
        (.networkFailed, "NetworkFailed"),
    ])
    func reportsNativeHostAndFailure(
        kind: RelayFailureKind,
        code: String
    ) throws {
        let diagnostic = RelayConnectionDiagnostic(
            host: "relay.example.test", port: 443, connected: false, failure: kind)
        let description = try #require(diagnostic.failureDescription)
        #expect(description.contains("relay.example.test:443"))
        #expect(description.contains(code))
    }

    @Test func connectedRelayHasNoFailureDescription() {
        let diagnostic = RelayConnectionDiagnostic(
            host: "relay.example.test", port: 443, connected: true, failure: .unknownIssuer)
        #expect(diagnostic.failureDescription == nil)
    }

    @Test func oldNotificationCannotChangeTheCurrentSnapshot() async throws {
        let observer = CmxIrohRelayDiagnosticObserver()
        try await observer.onChange(diagnostics: [
            .init(host: "relay.example.test", port: nil, connected: false, failure: .unknownIssuer),
        ])
        let current = RelayConnectionDiagnostic(
            host: "relay.example.test", port: nil, connected: false, failure: nil)
        #expect(current.failureDescription == nil)
    }
}
