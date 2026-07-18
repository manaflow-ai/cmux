import CMUXMobileCore
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
}
