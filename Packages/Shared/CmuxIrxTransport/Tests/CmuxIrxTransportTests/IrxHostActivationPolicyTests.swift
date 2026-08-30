import CmuxIrohTransport
import Foundation
import Testing

@testable import CmuxIrxTransport

@Suite("irx host activation policy")
struct IrxHostActivationPolicyTests {
    private let policy = IrxHostActivationPolicy(
        retrySchedule: CmxIrohRetrySchedule(
            initialDelay: 1,
            maximumDelay: 8,
            jitterFraction: 0
        )
    )

    @Test("a rejected refresh fails closed into reauthentication")
    func refreshRejectionStopsRetrying() {
        let failure = IrxBrokerFailure(
            operation: .register,
            error: CmxIrohBrokerTokenRecoveryError.authenticationRequired
        )
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
            ) == .reauthenticationRequired
        )
        #expect(failure.operation == .register)
        #expect(failure.errorCode == "unauthorized")
        #expect(failure.journalAttributes["operation"] == "register")
        #expect(failure.journalAttributes["error_code"] == "unauthorized")
    }

    @Test("transient broker failures use a bounded exponential ladder")
    func transientFailuresBackOff() {
        let failure = IrxBrokerFailure(
            operation: .discover,
            error: CmxIrohTrustBrokerClientError.connectivity
        )
        let delays = (0 ..< 5).map { count in
            policy.decision(
                for: failure,
                failureCount: count,
                jitterUnitInterval: 0
            )
        }
        #expect(delays == [
            .retry(delay: 1, retryAfterSeconds: nil),
            .retry(delay: 2, retryAfterSeconds: nil),
            .retry(delay: 4, retryAfterSeconds: nil),
            .retry(delay: 8, retryAfterSeconds: nil),
            .retry(delay: 8, retryAfterSeconds: nil),
        ])
    }

    @Test("a server retry floor is honored without exceeding the cap")
    func retryAfterFloorIsBounded() {
        let failure = IrxBrokerFailure(
            operation: .mint,
            error: CmxIrohTrustBrokerClientError.rateLimited(
                code: "account_budget",
                retryAfterSeconds: 30
            )
        )
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
        ) == .retry(delay: 8, retryAfterSeconds: 30)
        )
    }

    @Test("repeated transient failures remain bounded instead of hammering")
    func repeatedFailuresStayWithinTheCap() {
        let failure = IrxBrokerFailure(
            operation: .register,
            error: CmxIrohTrustBrokerClientError.connectivity
        )
        for count in 0 ... 100 {
            guard case let .retry(delay, _) = policy.decision(
                for: failure,
                failureCount: count,
                jitterUnitInterval: 0
            ) else {
                Issue.record("connectivity should remain retryable")
                return
            }
            #expect(delay <= 8)
        }
    }

    @Test("non-transient broker failures do not create a retry loop")
    func nonTransientFailureStops() {
        let failure = IrxBrokerFailure(
            operation: .hintRefresh,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 422,
                code: "invalid_request"
            )
        )
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
        ) == .stopped
        )
    }

    @Test("a stale binding proof is retryable after the cache is invalidated")
    func staleBindingProofDoesNotLookLikeReauthentication() {
        let failure = IrxBrokerFailure(
            operation: .mint,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 403,
                code: "invalid_binding_request_proof"
            )
        )
        #expect(!failure.requiresReauthentication)
        guard case .retry = policy.decision(
            for: failure,
            failureCount: 0,
            jitterUnitInterval: 0
        ) else {
            Issue.record("stale proof should use the transient retry ladder")
            return
        }
    }
}
