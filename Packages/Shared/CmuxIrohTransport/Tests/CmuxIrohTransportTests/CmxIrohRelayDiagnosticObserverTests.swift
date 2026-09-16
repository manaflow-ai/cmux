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
    ) async throws {
        let observer = CmxIrohRelayDiagnosticObserver()
        try await observer.onChange(diagnostics: [
            .init(host: "relay.example.test", port: 443, connected: false, failure: kind),
        ])
        let description = try #require(await observer.failureDescription)
        #expect(description.contains("relay.example.test:443"))
        #expect(description.contains(code))
    }

    @Test func connectedRelayHasNoFailureDescription() async throws {
        let observer = CmxIrohRelayDiagnosticObserver()
        try await observer.onChange(diagnostics: [
            .init(host: "relay.example.test", port: nil, connected: false, failure: .unknownIssuer),
        ])
        #expect(await observer.failureDescription?.contains("UnknownIssuer") == true)
        try await observer.onChange(diagnostics: [
            .init(host: "relay.example.test", port: 443, connected: true, failure: nil),
        ])
        #expect(await observer.failureDescription == nil)
    }

    @Test func successfulRevalidationClearsAnEarlyDiscoveryFailure() async throws {
        let observer = CmxIrohRelayDiagnosticObserver()
        try await observer.onChange(diagnostics: [
            .init(host: "relay.example.test", port: nil, connected: false, failure: .unknownIssuer),
        ])
        #expect(await observer.failureDescription?.contains("UnknownIssuer") == true)
        try await observer.onChange(diagnostics: [])
        #expect(await observer.failureDescription == nil)
    }
}
