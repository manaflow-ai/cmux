import CmuxIrohTransport
import Testing

@testable import CmuxIrxTransport

@Suite("irx broker failure diagnostics")
struct IrxBrokerFailureDiagnosticsTests {
    @Test("a post-recovery 401 is reported as credential unavailable")
    func postRecoveryUnauthorizedUsesCredentialCategory() {
        let failure = IrxBrokerFailure(
            operation: .discover,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        )

        #expect(failure.diagnosticFailureKind == .credentialUnavailable)
    }

    @Test("too early is a broker policy failure, not a timeout")
    func tooEarlyUsesPolicyCategory() {
        let failure = IrxBrokerFailure(
            operation: .register,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 425,
                code: "too_early"
            )
        )

        #expect(failure.diagnosticFailureKind == .policyUnavailable)
    }

    @Test("free-form broker text is replaced by a stable status code")
    func freeFormErrorCodeIsNotPublished() {
        let failure = IrxBrokerFailure(
            operation: .mint,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "token expired for account alice\nsecret"
            )
        )

        #expect(failure.diagnosticErrorCode == "http_401")
        #expect(failure.journalAttributes["error_code"] == "http_401")
    }
}
