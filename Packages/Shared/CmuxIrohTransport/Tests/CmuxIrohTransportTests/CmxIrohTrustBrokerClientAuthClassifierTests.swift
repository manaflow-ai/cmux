import Foundation
import Testing
@testable import CmuxIrohTransport

/// Regression coverage for the wake-time authorization outage: a broker 401
/// used to tear down the whole verified runtime (endpoint, routes, offline
/// cache) and nap for 30s+ of backoff, turning a seconds-long token rotation
/// race into a multi-minute connectivity gap on every app foreground.
struct CmxIrohTrustBrokerClientAuthClassifierTests {
    @Test
    func unauthorizedRejectionPreservesVerifiedStateDuringRefresh() {
        #expect(CmxIrohTrustBrokerClientError.preservesVerifiedStateDuringRefresh(
            CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        ))
        #expect(!CmxIrohTrustBrokerClientError.preservesVerifiedStateDuringRefresh(
            CmxIrohTrustBrokerClientError.rejected(statusCode: 403, code: nil)
        ))
    }

    @Test
    func unauthorizedRejectionRetriesInitialActivation() {
        #expect(!CmxIrohTrustBrokerClientError.retriesInitialActivation(
            CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        ))
        // 401 and 403 can both be durable authorization failures; initial
        // activation must return them to the auth lifecycle instead of spin.
        #expect(!CmxIrohTrustBrokerClientError.retriesInitialActivation(
            CmxIrohTrustBrokerClientError.rejected(statusCode: 403, code: nil)
        ))
    }
}
