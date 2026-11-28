import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Replies

    /// One daemon reply for the account signed in now. A reply that arrives
    /// after sign-out or an account switch is refused (`notAuthorized`), so
    /// no page of the previous account reaches the store. A failure that
    /// leaves intents unconfirmed marks the source degraded; a good reply
    /// recovers it. A refusal for a missing or expired lease
    /// (`cloud_signed_out`: another trusted local client cleared it;
    /// `cloud_session_expired`) means nothing was sent: the source holds
    /// the account unleased and asks the link for a lease.
    func reply<T>(for identity: CloudIdentity, _ body: () async throws -> T) async throws -> T {
        let epoch = state.withLock { $0.leaseEpoch }
        let value: T
        do {
            value = try await body()
        } catch {
            let rejection = Self.rejection(for: error)
            if Self.isNoLease(error) { leaseLost(for: identity) }
            // Only the account that sent it waits for a recovery.
            if rejection == .indeterminate || rejection == .ownerUnreachable {
                state.withLock { if $0.identity?.cloudID == identity.cloudID { $0.degraded = true } }
            }
            throw rejection
        }
        guard state.withLock({ $0.identity?.cloudID }) == identity.cloudID else { throw HomeRejection.notAuthorized }
        reached(leaseEpoch: epoch)
        return value
    }

    /// The daemon holds no lease for `identity`, which this source still
    /// acts as: nothing goes out until the link leases it again.
    private func leaseLost(for identity: CloudIdentity) {
        let missing = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.identity?.cloudID == identity.cloudID, state.leased else { return nil }
            state.leased = false
            return state.leaseMissing
        }
        missing?()
    }

    /// The daemon holds no usable lease: none (`cloud_signed_out`), or one
    /// that expired (`cloud_session_expired`, possibly one another trusted
    /// local client set).
    private static func isNoLease(_ error: any Error) -> Bool {
        guard case .command(_, _, let code, _, _) = error as? DaemonError else { return false }
        return code == "cloud_signed_out" || code == "cloud_session_expired"
    }

    /// The daemon's answers as `HomeRejection` (home-cloud-proxy.md section 6).
    static func rejection(for error: any Error) -> HomeRejection {
        switch error {
        case let rejection as HomeRejection: rejection
        case let error as DaemonError: rejection(error)
        default: .indeterminate
        }
    }

    static func rejection(_ error: DaemonError) -> HomeRejection {
        switch error {
        case .command(_, let message, let code, _, let retryable):
            let reason = error.rejectReason ?? message
            switch code {
            case "cloud_conversation_rejected":
                if retryable == true { return .rateLimited(retryAfter: nil) }
                return reason == "forbidden" ? .notAuthorized : .invalid(reason)
            // Refused before the owner saw it: nothing committed; resent after a
            // new lease (no lease at all: the source asks for one, `reply`).
            case "cloud_signed_out", "cloud_session_expired", "cloud_unauthenticated": return .ownerUnreachable
            // The outcome of a mutation is unknown: resend with the same key.
            case "cloud_unavailable": return .indeterminate
            default: return .invalid(reason)
            }
        case .notConnected, .missingCapabilities: return .ownerUnreachable
        default: return .indeterminate
        }
    }
}
