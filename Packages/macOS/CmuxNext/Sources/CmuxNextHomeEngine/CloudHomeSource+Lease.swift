import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Lease

    /// Called (off any lock) when an op or read is refused because the
    /// daemon holds no lease for this account: nothing reaches the daemon
    /// then, so the daemon never asks for one itself.
    func onLeaseMissing(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.leaseMissing = action }
    }

    /// Called (off any lock) when the first reply, live socket or owner
    /// event after a renewed lease shows the Worker takes its token.
    func onLeaseProven(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.leaseProven = action }
    }

    /// The daemon took a new lease for `subject` (a Stack user id). Only a
    /// lease for the account this source acts as counts: refused ops can go
    /// through again, and an account that waited for its first lease lists
    /// its inbox. A lease for another account changes nothing here.
    func leaseRenewed(subject: String) {
        let renewed = state.withLock { state -> (first: Bool, generation: UInt64)? in
            guard let identity = state.identity, identity.cloudID == CloudIdentity.cloudID(stackUserID: subject) else { return nil }
            defer {
                state.leased = true
                // A lease is not proof: the Worker may refuse its token too.
                state.proven = false
                state.leaseEpoch += 1
            }
            return (!state.leased, state.generation)
        }
        guard let renewed else { return }
        if renewed.first {
            leaseArrived(generation: renewed.generation)
        } else {
            recover()
        }
    }

    /// The first lease of this generation's account: what waited for it goes again.
    func leaseArrived(generation: UInt64) {
        recover()
        // task-owner: one inbox list; ends with its reply
        Task { [weak self] in await self?.reloadInbox(generation: generation) }
    }

    /// A reply, a live socket or an owner event: the cloud and the Worker
    /// took this lease. The link stops spacing renewals, and what failed
    /// before goes again.
    /// `leaseEpoch`: the lease a reply was sent under; a reply sent before
    /// the current lease proves nothing about it.
    func reached(leaseEpoch: UInt64? = nil) {
        let proven = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.proven, leaseEpoch.map({ $0 == state.leaseEpoch }) ?? true else { return nil }
            state.proven = true
            return state.leaseProven
        }
        proven?()
        recover()
    }

    /// The cloud is reachable again after a failure: the store resends.
    private func recover() {
        publish { state in
            guard state.degraded, state.identity != nil, state.leased, state.commands != nil else { return nil }
            state.degraded = false
            return .ownerRecovered
        }
    }
}
