import CmuxIrohTransport
import Foundation
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

    @Test("an unknown token-shaped broker code falls back to status")
    func tokenShapedUnknownCodeIsNotPublished() {
        let failure = IrxBrokerFailure(
            operation: .discover,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 502,
                code: "tok_01J9QX5V8P7R4M2N"
            )
        )

        #expect(failure.diagnosticErrorCode == "http_502")
    }

    @Test("known broker codes remain available to diagnostics")
    func knownBrokerCodeIsPublished() {
        let failure = IrxBrokerFailure(
            operation: .mint,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 429,
                code: "rate_limited:account_budget"
            )
        )

        #expect(failure.diagnosticErrorCode == "rate_limited:account_budget")
    }

    @Test("connectivity causes retain safe transport attribution")
    func connectivityCauseIsAttributed() {
        let failure = IrxBrokerFailure(
            operation: .mint,
            error: CmxIrohTrustBrokerClientError.connectivity(
                CmxIrohBrokerConnectivityCause(
                    urlErrorCode: URLError.Code.networkConnectionLost.rawValue
                )
            )
        )

        #expect(String(describing: failure).contains("networkConnectionLost(-1005)"))
        #expect(failure.diagnosticErrorCode == "connectivity_network_connection_lost")
        #expect(failure.diagnosticFailureKind == .offline)
        #expect(failure.journalAttributes["operation"] == "mint")
        #expect(
            failure.journalAttributes["error_code"]
                == "connectivity_network_connection_lost"
        )
        #expect(
            failure.journalAttributes["transport_error_code"]
                == "networkConnectionLost(-1005)"
        )
    }
}
