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
        let description = try #require(CmxIrohRelayDiagnosticObserver.failureDescription(for: [
            .init(host: "relay.example.test", port: 443, connected: false, failure: kind),
        ]))
        #expect(description.contains("relay.example.test:443"))
        #expect(description.contains(code))
    }

    @Test func connectedRelayHasNoFailureDescription() {
        #expect(CmxIrohRelayDiagnosticObserver.failureDescription(for: [
            .init(host: "relay.example.test", port: 443, connected: true, failure: .unknownIssuer),
        ]) == nil)
    }

    @Test func oldNotificationCannotChangeTheCurrentSnapshot() async throws {
        let observer = CmxIrohRelayDiagnosticObserver()
        try await observer.onChange(diagnostics: [
            .init(host: "relay.example.test", port: nil, connected: false, failure: .unknownIssuer),
        ])
        #expect(CmxIrohRelayDiagnosticObserver.failureDescription(for: []) == nil)
    }
}
