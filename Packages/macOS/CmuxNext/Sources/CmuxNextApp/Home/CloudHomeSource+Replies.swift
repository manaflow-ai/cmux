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
            let reply = CloudReplyError(error)
            let rejection = reply.rejection
            if reply.isNoLease { leaseLost(for: identity) }
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
}
