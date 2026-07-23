import CMUXMobileCore
import IrohLib
import Testing

@testable import CmuxIrohTransport

@Suite struct CmxIrohDiagnosticFailureTests {
    @Test func mapsRepresentativeFailuresWithoutInspectingAssociatedText() {
        #expect(
            DiagnosticFailureKind.classify(
                CmxIrohTrustBrokerClientError.rejected(statusCode: 403, code: "private-code")
            ) == .authorizationFailed
        )
        #expect(
            DiagnosticFailureKind.classify(
                CmxIrohLibError.unmanagedRelayURL("https://private-relay.example")
            ) == .policyUnavailable
        )
        #expect(
            DiagnosticFailureKind.classify(CmxIrohGrantVerifierError.accountMismatch)
                == .accountMismatch
        )
        #expect(
            DiagnosticFailureKind.classify(CmxIrohClientSessionError.admissionDenied(code: 9))
                == .admissionDenied
        )
        #expect(
            DiagnosticFailureKind.classify(CmxIrohKeychainIdentityStoreError(status: -50))
                == .credentialUnavailable
        )
        #expect(
            DiagnosticFailureKind.classify(CmxIrohClientRuntimeError.superseded)
                == .superseded
        )
    }

    @Test(arguments: [
        ("ConnectionLost(TimedOut)", DiagnosticFailureKind.transportIdleTimedOut),
        ("timed out", DiagnosticFailureKind.timedOut),
        ("ConnectionLost(Reset)", DiagnosticFailureKind.connectionClosed),
        (
            "ConnectionLost(TransportError(TransportError { code: INTERNAL_ERROR }))",
            DiagnosticFailureKind.connectionClosed
        ),
        (
            "ConnectionLost(ApplicationClosed(ApplicationClose { error_code: 0 }))",
            DiagnosticFailureKind.connectionClosed
        ),
        (
            "ConnectionLost(ConnectionClosed(ConnectionClose { error_code: 0 }))",
            DiagnosticFailureKind.connectionClosed
        ),
        ("ConnectionLost(LocallyClosed)", DiagnosticFailureKind.cancelled),
        (
            "No addressing information available\nCaused by:\n    All address lookup services failed or produced no results",
            DiagnosticFailureKind.dnsFailed
        ),
        (
            "Failed to connect to relay server\nCaused by:\n    Failed to resolve",
            DiagnosticFailureKind.dnsFailed
        ),
        (
            "Error constructing TLS configuration\nCaused by:\n    The configured crypto provider is incompatible with iroh and QUIC encryption",
            DiagnosticFailureKind.secureChannelFailed
        ),
        (
            "ConnectionLost(TransportError(Error { code: Code::crypto(2a), reason: \"TLS error\" }))",
            DiagnosticFailureKind.secureChannelFailed
        ),
        ("ReadError(ClosedStream)", DiagnosticFailureKind.connectionClosed),
        ("opaque unclassified bridge failure", DiagnosticFailureKind.unknown),
    ])
    func mapsPinnedIrohFFIErrors(
        message: String,
        expected: DiagnosticFailureKind
    ) {
        #expect(
            DiagnosticFailureKind.classify(TestIrohError(message: message))
                == expected
        )
    }
}

private final class TestIrohError: IrohError, @unchecked Sendable {
    private let testMessage: String

    required init(unsafeFromHandle handle: UInt64) {
        testMessage = ""
        super.init(unsafeFromHandle: handle)
    }

    init(message: String) {
        testMessage = message
        super.init(noHandle: NoHandle())
    }

    override func message() -> String {
        testMessage
    }
}
