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

    @Test("a missing snapshot stays retryable during account transitions")
    func missingAuthenticationRetries() {
        let failure = IrxBrokerFailure(
            operation: .register,
            error: CmxIrohTrustBrokerClientError.missingAuthentication
        )
        #expect(!failure.requiresReauthentication)
        guard case .retry = policy.decision(
            for: failure,
            failureCount: 0,
            jitterUnitInterval: 0
        ) else {
            Issue.record("a missing snapshot should use the transient ladder")
            return
        }
        guard case .retry = policy.decision(
            for: failure,
            failureCount: 20,
            jitterUnitInterval: 0
        ) else {
            Issue.record("a missing snapshot must remain on the transient ladder")
            return
        }
    }

    @Test("a wire error code cannot masquerade as missing authentication")
    func wireMissingAuthenticationCodeDoesNotEscalate() {
        let failure = IrxBrokerFailure(
            operation: .register,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 400,
                code: "missing_authentication"
            )
        )
        #expect(failure.escalationBucket == .transient)
        #expect(
            policy.decision(
                for: failure,
                failureCount: 20,
                jitterUnitInterval: 0
            ) == .stopped
        )
    }

    @Test("a status-bearing missing-auth code uses the generic backoff bucket")
    func statusBearingMissingAuthenticationUsesTransientLadder() {
        let failure = IrxBrokerFailure(
            operation: .mint,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 429,
                code: "missing_authentication"
            )
        )
        #expect(failure.escalationBucket == .transient)
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
            ) == .retry(delay: 1, retryAfterSeconds: nil)
        )
        #expect(
            policy.decision(
                for: failure,
                failureCount: 2,
                jitterUnitInterval: 0
            ) == .retry(delay: 4, retryAfterSeconds: nil)
        )
    }

    @Test("a second broker 401 stays on the bounded transient ladder")
    func finalBrokerUnauthorizedIsRetryableAfterRecovery() {
        let failure = IrxBrokerFailure(
            operation: .discover,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        )

        #expect(!failure.requiresReauthentication)
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
            ) == .retry(delay: 1, retryAfterSeconds: nil)
        )
        #expect(
            policy.decision(
                for: failure,
                failureCount: 2,
                jitterUnitInterval: 0
            ) == .reauthenticationRequired
        )
    }

    @Test("an auxiliary broker 401 backs off without owning reauthentication")
    func auxiliaryUnauthorizedUsesItsLocalBackoffCount() {
        let failure = IrxBrokerFailure(
            operation: .hintRefresh,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        )

        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0,
                escalateUnauthorized: false
            ) == .retry(delay: 1, retryAfterSeconds: nil)
        )
        #expect(
            policy.decision(
                for: failure,
                failureCount: 1,
                jitterUnitInterval: 0,
                escalateUnauthorized: false
            ) == .retry(delay: 2, retryAfterSeconds: nil)
        )
        #expect(
            policy.decision(
                for: failure,
                failureCount: 2,
                jitterUnitInterval: 0,
                escalateUnauthorized: false
            ) == .retry(delay: 4, retryAfterSeconds: nil)
        )
    }

    @Test("foreground renewal tolerates a short post-recovery auth race")
    func foregroundUnauthorizedLimitIsBoundedButNotPremature() {
        let foregroundPolicy = IrxHostActivationPolicy(
            retrySchedule: CmxIrohRetrySchedule(
                initialDelay: 1,
                maximumDelay: 8,
                jitterFraction: 0
            ),
            postRecoveryUnauthorizedFailureLimit: 4
        )
        let failure = IrxBrokerFailure(
            operation: .mint,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 401,
                code: "unauthorized"
            )
        )

        #expect(
            foregroundPolicy.decision(
                for: failure,
                failureCount: 3,
                jitterUnitInterval: 0
            ) == .retry(delay: 8, retryAfterSeconds: nil)
        )
        #expect(
            foregroundPolicy.decision(
                for: failure,
                failureCount: 4,
                jitterUnitInterval: 0
            ) == .reauthenticationRequired
        )
    }

    @Test("transient broker failures use a bounded exponential ladder")
    func transientFailuresBackOff() {
        let failure = IrxBrokerFailure(
            operation: .discover,
            error: CmxIrohTrustBrokerClientError.connectivity(nil)
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
            error: CmxIrohTrustBrokerClientError.connectivity(nil)
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

    @Test("unclassified local failures fail closed instead of retrying")
    func unclassifiedFailureStops() {
        let failure = IrxBrokerFailure(
            operation: .register,
            error: IrxHostActivationPolicyLocalInputError()
        )

        #expect(failure.kind == .invalid)
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
        ) == .stopped
        )
    }

    @Test("unmapped URL session failures remain transient")
    func unmappedURLFailureRemainsRetryable() async throws {
        let service = try IrxBrokerArmingSupport.makeService(
            identity: IrxBrokerArmingSupport.identity(),
            cacheDirectory: IrxBrokerArmingSupport.temporaryDirectory()
        )

        do {
            _ = try await service.withBrokerOperation(.discover) { () -> Void in
                throw URLError(.secureConnectionFailed)
            }
            Issue.record("Expected the URL session failure to be classified")
        } catch let failure as IrxBrokerFailure {
            #expect(failure.kind == .transient)
            #expect(failure.operation == .discover)
        }
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

    @Test("empty or stale relay responses stay on the retry ladder")
    func serviceMintFailuresRemainRetryable() {
        let failure = IrxBrokerFailure(
            operation: .mint,
            error: IrxBrokerServiceError.noCredentialsIssued
        )
        #expect(failure.kind == .transient)
        #expect(failure.errorCode == "no_credentials_issued")
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
        ) == .retry(delay: 1, retryAfterSeconds: nil)
        )
    }

    @Test("host retries preserve a broker floor beyond the foreground cap")
    func hostRetryUsesServerFloor() {
        let failure = IrxBrokerFailure(
            operation: .discover,
            error: CmxIrohTrustBrokerClientError.rateLimited(
                code: "slow_down",
                retryAfterSeconds: 300
            )
        )
        guard case let .retry(policyDelay, retryAfterSeconds) = policy.decision(
            for: failure,
            failureCount: 0,
            jitterUnitInterval: 0
        ) else {
            Issue.record("rate-limited discovery should remain retryable")
            return
        }
        let delay = IrxRelayCredentialPolicy().boundedRetryDelay(
            expiresAt: nil,
            now: Date(timeIntervalSince1970: 2_000_000),
            policyDelay: policyDelay,
            retryAfterSeconds: retryAfterSeconds
        )
        #expect(policyDelay == 8)
        #expect(delay == 300)
    }

    @Test("a missing revoke target does not enter the transient ladder")
    func revokeNotFoundStops() {
        let failure = IrxBrokerFailure(
            operation: .revoke,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 404,
                code: "not_found"
            )
        )
        #expect(failure.kind == .rejected)
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
        ) == .stopped
        )
    }

    @Test("activation route rollout stays on the bounded retry ladder")
    func activationBrokerNotFoundRetries() {
        let failure = IrxBrokerFailure(
            operation: .register,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 404,
                code: "not_found"
            )
        )
        #expect(failure.kind == .transient)
        #expect(
            policy.decision(
                for: failure,
                failureCount: 0,
                jitterUnitInterval: 0
            ) == .retry(delay: 1, retryAfterSeconds: nil)
        )
    }

    @Test("reachable broker outages keep actionable diagnostic categories")
    func transientBrokerDiagnosticsDistinguishReachability() {
        let rateLimited = IrxBrokerFailure(
            operation: .mint,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 429,
                code: "rate_limited"
            )
        )
        let serverUnavailable = IrxBrokerFailure(
            operation: .discover,
            error: CmxIrohTrustBrokerClientError.rejected(
                statusCode: 503,
                code: "unavailable"
            )
        )

        #expect(rateLimited.diagnosticFailureKind == .policyUnavailable)
        #expect(serverUnavailable.diagnosticFailureKind == .endpointUnavailable)
        #expect(
            IrxBrokerFailure(
                operation: .discover,
                error: CmxIrohTrustBrokerClientError.connectivity(nil)
            ).diagnosticFailureKind == .offline
        )
    }

    @Test("broker token recovery errors retain operation context")
    func brokerOperationPreservesTokenRecoveryClassification() async throws {
        let service = try IrxBrokerArmingSupport.makeService(
            identity: IrxBrokerArmingSupport.identity(),
            cacheDirectory: IrxBrokerArmingSupport.temporaryDirectory()
        )
        do {
            _ = try await service.withBrokerOperation(.mint) { () -> Void in
                throw CmxIrohBrokerTokenRecoveryError.authenticationRequired
            }
            Issue.record("Expected a classified auth failure")
        } catch let failure as IrxBrokerFailure {
            #expect(failure.operation == .mint)
            #expect(failure.requiresReauthentication)
            #expect(failure.errorCode == "unauthorized")
        }
    }
}
