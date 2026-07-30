import CmuxMobileRPC
import Testing
@testable import CmuxMobileShell

/// Exhaustive table for docs/transport-plane.md D2/D3: app-level evidence
/// never tears down a session the transport reports healthy.
struct MobileConnectionPolicyTests {
    private func context(
        connected: Bool = true,
        health: MobileTransportPathHealth = .unknown,
        blocked: Bool = false,
        repairs: Int = 0
    ) -> MobileConnectionPolicyContext {
        MobileConnectionPolicyContext(
            isConnected: connected,
            pathHealth: health,
            automaticReconnectBlocked: blocked,
            consecutiveRepairAttempts: repairs
        )
    }

    // MARK: Invariant I1 — healthy path is never torn down by suspect evidence

    @Test func healthyPathSuspectEvidenceNeverRedials() {
        let suspect: [MobileConnectionEvidence] = [
            .livenessSilence, .eventStreamEnded,
            .subscriptionStartFailed, .rpcWriteTimedOut,
        ]
        for evidence in suspect {
            for repairs in 0...3 {
                let action = MobileConnectionPolicy.action(
                    for: evidence,
                    in: context(health: .healthy, repairs: repairs)
                )
                #expect(action != .redial, "\(evidence) repairs=\(repairs)")
                #expect(
                    action != .stopUntilAuthorizationRepaired,
                    "\(evidence) repairs=\(repairs)"
                )
            }
        }
    }

    @Test func healthyPathOpportunityEvidenceNeverRedials() {
        let opportunity: [MobileConnectionEvidence] = [
            .foreground, .networkPathChanged, .presenceRoutePush,
            .manualRetry, .backoffExpired,
        ]
        for evidence in opportunity {
            let action = MobileConnectionPolicy.action(
                for: evidence,
                in: context(health: .healthy)
            )
            #expect(action != .redial, "\(evidence)")
        }
    }

    // MARK: Suspect-evidence ladder

    @Test func livenessSilenceOnHealthyPathRepairsInPlaceFirst() {
        #expect(MobileConnectionPolicy.action(
            for: .livenessSilence, in: context(health: .healthy)
        ) == .resubscribe)
        #expect(MobileConnectionPolicy.action(
            for: .eventStreamEnded, in: context(health: .healthy)
        ) == .resubscribe)
    }

    @Test func repeatedRepairsEscalateToProbeNotRedial() {
        #expect(MobileConnectionPolicy.action(
            for: .livenessSilence, in: context(health: .healthy, repairs: 1)
        ) == .probeThenEscalate)
        #expect(MobileConnectionPolicy.action(
            for: .eventStreamEnded, in: context(health: .healthy, repairs: 2)
        ) == .probeThenEscalate)
    }

    @Test func controlPlaneFailuresOnHealthyPathProbeInsteadOfBlindRetry() {
        #expect(MobileConnectionPolicy.action(
            for: .subscriptionStartFailed, in: context(health: .healthy)
        ) == .probeThenEscalate)
        #expect(MobileConnectionPolicy.action(
            for: .rpcWriteTimedOut, in: context(health: .healthy)
        ) == .probeThenEscalate)
    }

    @Test func deadPathEscalatesSuspectEvidenceToRedial() {
        let suspect: [MobileConnectionEvidence] = [
            .livenessSilence, .eventStreamEnded,
            .subscriptionStartFailed, .rpcWriteTimedOut,
        ]
        for evidence in suspect {
            #expect(MobileConnectionPolicy.action(
                for: evidence, in: context(health: .noPath)
            ) == .redial, "\(evidence)")
        }
    }

    // MARK: Unknown health preserves pre-gate behavior

    @Test func unknownHealthKeepsLegacyEscalation() {
        #expect(MobileConnectionPolicy.action(
            for: .livenessSilence, in: context(health: .unknown)
        ) == .probeThenEscalate)
        #expect(MobileConnectionPolicy.action(
            for: .eventStreamEnded, in: context(health: .unknown)
        ) == .redial)
        #expect(MobileConnectionPolicy.action(
            for: .subscriptionStartFailed, in: context(health: .unknown)
        ) == .redial)
        #expect(MobileConnectionPolicy.action(
            for: .rpcWriteTimedOut, in: context(health: .unknown)
        ) == .redial)
    }

    // MARK: Health-fatal and authorization evidence

    @Test func transportClosedRedialsWhileConnectedOnly() {
        #expect(MobileConnectionPolicy.action(
            for: .transportClosed, in: context(connected: true, health: .healthy)
        ) == .redial)
        #expect(MobileConnectionPolicy.action(
            for: .allPathsUnavailable, in: context(connected: true)
        ) == .redial)
        #expect(MobileConnectionPolicy.action(
            for: .transportClosed, in: context(connected: false)
        ) == .none)
    }

    @Test func authorizationLossStopsRegardlessOfHealth() {
        for health in [MobileTransportPathHealth.healthy, .noPath, .unknown] {
            for connected in [true, false] {
                #expect(MobileConnectionPolicy.action(
                    for: .authorizationLost,
                    in: context(connected: connected, health: health)
                ) == .stopUntilAuthorizationRepaired)
            }
        }
    }

    // MARK: Opportunity evidence while disconnected

    @Test func opportunityEvidenceDialsWhenUnblocked() {
        let automatic: [MobileConnectionEvidence] = [
            .foreground, .networkPathChanged, .presenceRoutePush, .backoffExpired,
        ]
        for evidence in automatic {
            #expect(MobileConnectionPolicy.action(
                for: evidence, in: context(connected: false)
            ) == .redial, "\(evidence)")
            #expect(MobileConnectionPolicy.action(
                for: evidence, in: context(connected: false, blocked: true)
            ) == .none, "\(evidence)")
        }
    }

    @Test func manualRetryIgnoresAutomaticBackoff() {
        #expect(MobileConnectionPolicy.action(
            for: .manualRetry, in: context(connected: false, blocked: true)
        ) == .redial)
        #expect(MobileConnectionPolicy.action(
            for: .manualRetry, in: context(connected: true, blocked: true)
        ) == .probeThenEscalate)
    }

    @Test func connectedOpportunitiesProbeOrNoop() {
        #expect(MobileConnectionPolicy.action(
            for: .foreground, in: context(health: .unknown)
        ) == .probeThenEscalate)
        #expect(MobileConnectionPolicy.action(
            for: .networkPathChanged, in: context(health: .healthy)
        ) == .probeThenEscalate)
        #expect(MobileConnectionPolicy.action(
            for: .presenceRoutePush, in: context(health: .healthy)
        ) == .none)
        #expect(MobileConnectionPolicy.action(
            for: .presenceRoutePush, in: context(health: .noPath)
        ) == .redial)
        #expect(MobileConnectionPolicy.action(
            for: .backoffExpired, in: context(connected: true)
        ) == .none)
    }

    // MARK: Suspect evidence while disconnected is moot

    @Test func suspectEvidenceWhileDisconnectedIsIgnored() {
        let suspect: [MobileConnectionEvidence] = [
            .livenessSilence, .eventStreamEnded,
            .subscriptionStartFailed, .rpcWriteTimedOut,
        ]
        for evidence in suspect {
            #expect(MobileConnectionPolicy.action(
                for: evidence, in: context(connected: false)
            ) == .none, "\(evidence)")
        }
    }

    // MARK: Totality — every evidence/context combination has a decision

    @Test func policyIsTotal() {
        for evidence in MobileConnectionEvidence.allCases {
            for connected in [true, false] {
                for health in [MobileTransportPathHealth.healthy, .noPath, .unknown] {
                    for blocked in [true, false] {
                        for repairs in [0, 1, 5] {
                            _ = MobileConnectionPolicy.action(
                                for: evidence,
                                in: context(
                                    connected: connected,
                                    health: health,
                                    blocked: blocked,
                                    repairs: repairs
                                )
                            )
                        }
                    }
                }
            }
        }
    }
}
