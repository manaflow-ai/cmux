import Foundation
import Testing
@testable import CmuxIrohTransport

/// Regression coverage for the wake-time authorization outage: a broker 401
/// used to tear down the whole verified runtime (endpoint, routes, offline
/// cache) and nap for 30s+ of backoff, turning a seconds-long token rotation
/// race into a multi-minute connectivity gap on every app foreground.
struct CmxIrohTrustBrokerClientAuthClassifierTests {
    @Test
    func unauthorizedRejectionPreservesVerifiedPolicyDuringRefresh() {
        #expect(CmxIrohTrustBrokerClientError.preservesVerifiedPolicyDuringRefresh(
            CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        ))
        #expect(!CmxIrohTrustBrokerClientError.preservesVerifiedPolicyDuringRefresh(
            CmxIrohTrustBrokerClientError.rejected(statusCode: 403, code: nil)
        ))
    }

    @Test
    func unauthorizedRejectionRetriesInitialActivation() {
        #expect(CmxIrohTrustBrokerClientError.retriesInitialActivation(
            CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        ))
        // 403 can be a durable permission denial; initial activation must not
        // spin on it.
        #expect(!CmxIrohTrustBrokerClientError.retriesInitialActivation(
            CmxIrohTrustBrokerClientError.rejected(statusCode: 403, code: nil)
        ))
    }
}
