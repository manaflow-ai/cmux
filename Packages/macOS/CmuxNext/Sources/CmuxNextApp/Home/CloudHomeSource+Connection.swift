import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Synchronization

extension CloudHomeSource {
    fileprivate func requireEndpoint(binding key: String? = nil) throws -> (any CloudConversationCommands, CloudIdentity, UInt64) {
        var missing: (@Sendable () -> Void)?
        let endpoint = state.withLock { state -> Result<(any CloudConversationCommands, CloudIdentity, UInt64), HomeRejection> in
            guard let identity = state.identity else { return .failure(.notAuthorized) }
            if let key {
                if state.revoked[key] != nil { return .failure(.notAuthorized) }
                state.accepted.insert(key)
            }
            guard let commands = state.commands else {
                state.degraded = true
                return .failure(.ownerUnreachable)
            }
            guard state.leased else {
                state.degraded = true
                missing = state.leaseMissing
                return .failure(.ownerUnreachable)
            }
            return .success((commands, identity, state.generation))
        }
        missing?()
        return try endpoint.get()
    }

    /// One daemon reply for the account signed in now. A reply that arrives
    /// after sign-out or an account switch is refused (`notAuthorized`), so
    /// no page of the previous account reaches the store. A failure that
    /// leaves intents unconfirmed marks the source degraded; a good reply
    /// recovers it. A refusal for a missing or expired lease
    /// (`cloud_signed_out`: another trusted local client cleared it;
    /// `cloud_session_expired`) means nothing was sent: the source holds
    /// the account unleased and asks the link for a lease.
    fileprivate func reply<T>(for identity: CloudIdentity, _ body: () async throws -> T) async throws -> T {
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
    fileprivate func leaseLost(for identity: CloudIdentity) {
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
    fileprivate static func isNoLease(_ error: any Error) -> Bool {
        guard case .command(_, _, let code, _, _) = error as? DaemonError else { return false }
        return code == "cloud_signed_out" || code == "cloud_session_expired"
    }

    /// Ends subscriptions of conversations the inbox no longer lists.
    fileprivate func unsubscribe(_ ids: [ConversationID], commands: (any CloudConversationCommands)?) {
        guard let commands, !ids.isEmpty else { return }
        state.withLock { Self.chainUnsubscribes(ids, commands: commands, &$0) }
    }

    /// Queues unsubscribes after the subscribes and unsubscribes queued
    /// before (call with the lock held).
    fileprivate static func chainUnsubscribes(_ ids: [ConversationID], commands: any CloudConversationCommands, _ state: inout State) {
        let prior = state.wire
        // task-owner: one unsubscribe per conversation, after the earlier ones; ends with the replies
        state.wire = Task {
            await prior?.value
            for id in ids { _ = try? await commands.unsubscribe(id.rawValue) }
        }
    }

    /// Queues a subscribe after the subscribes and unsubscribes queued
    /// before; the task answers with its reply (call with the lock held).
    fileprivate static func chainSubscribe(_ id: ConversationID, commands: any CloudConversationCommands,
                                       _ state: inout State) -> Task<Result<CloudSubscription, any Error>, Never> {
        let prior = state.wire
        // task-owner: one subscribe, after the earlier ones; ends with its reply
        let sent = Task { () -> Result<CloudSubscription, any Error> in
            await prior?.value
            do { return .success(try await commands.subscribe(id.rawValue)) } catch { return .failure(error) }
        }
        // task-owner: the queue's link to that subscribe; ends with it
        state.wire = Task { _ = await sent.value }
        return sent
    }

    /// An edit of `conversation` starts: a deadline waiting for an earlier
    /// edit's echo waits for this one's op too.
    fileprivate func beginEdit(_ conversation: ConversationID, generation: UInt64) {
        state.withLock { state in
            guard state.generation == generation else { return }
            var hold = state.editHolds[conversation]
                ?? EditHold(deadline: DemandTimer(owner: "App.homeCloud.editEcho", clock: clock))
            hold.inFlight += 1
            hold.deadline.cancel()
            state.editHolds[conversation] = hold
        }
    }

    /// An edit's op answered (`committedAt`: its revision) or was refused
    /// (`final`: the store never resends it). Once no edit of the
    /// conversation is in flight, the subscription ends when the newest
    /// committed edit's echo has arrived, or at once when nothing waits for
    /// one; otherwise at the echo or at `editEchoDeadline`, whichever comes
    /// first. A transcript that shows the conversation keeps its own.
    fileprivate func finishEdit(_ conversation: ConversationID, generation: UInt64, committedAt rev: UInt64?, final: Bool) {
        state.withLock { state in
            guard state.generation == generation, var hold = state.editHolds[conversation] else { return }
            hold.inFlight = max(hold.inFlight - 1, 0)
            if let rev { hold.awaited = max(hold.awaited ?? 0, rev) }
            state.editHolds[conversation] = hold
            guard hold.inFlight == 0 else { return }
            if state.viewed.contains(conversation) {
                state.editHolds[conversation] = nil
                return
            }
            let echoed = hold.awaited.map { hold.seen >= $0 } ?? final
            if echoed {
                endEditSubscription(conversation, &state)
                return
            }
            hold.deadline.schedule(after: Self.editEchoDeadline) { [weak self] in
                self?.editDeadlinePassed(conversation, generation: generation)
            }
        }
    }

    /// A conversation event at `rev`: the echo of a held edit ends its subscription.
    fileprivate func echoed(_ conversation: ConversationID, rev: UInt64) {
        state.withLock { state in
            guard var hold = state.editHolds[conversation] else { return }
            hold.seen = max(hold.seen, rev)
            state.editHolds[conversation] = hold
            guard hold.inFlight == 0, let awaited = hold.awaited, hold.seen >= awaited else { return }
            endEditSubscription(conversation, &state)
        }
    }

    fileprivate func editDeadlinePassed(_ conversation: ConversationID, generation: UInt64) {
        state.withLock { state in
            // An edit in flight arms the deadline again when it answers.
            guard state.generation == generation, state.editHolds[conversation]?.inFlight == 0 else { return }
            endEditSubscription(conversation, &state)
        }
    }

    /// The held edit is done: no transcript shows its conversation, so the
    /// subscription `requireEditable` made for it ends (call with the lock
    /// held).
    fileprivate func endEditSubscription(_ conversation: ConversationID, _ state: inout State) {
        state.editHolds.removeValue(forKey: conversation)?.deadline.cancel()
        guard !state.viewed.contains(conversation), let commands = state.commands,
              state.targets.removeValue(forKey: conversation) != nil else { return }
        state.recent.removeAll { $0 == conversation }
        Self.chainUnsubscribes([conversation], commands: commands, &state)
    }

    /// A reply, a live socket or an owner event: the cloud and the Worker
    /// took this lease. The link stops spacing renewals, and what failed
    /// before goes again.
    /// `leaseEpoch`: the lease a reply was sent under; a reply sent before
    /// the current lease proves nothing about it.
    fileprivate func reached(leaseEpoch: UInt64? = nil) {
        let proven = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.proven, leaseEpoch.map({ $0 == state.leaseEpoch }) ?? true else { return nil }
            state.proven = true
            return state.leaseProven
        }
        proven?()
        recover()
    }

    /// The cloud is reachable again after a failure: the store resends.
    fileprivate func recover() {
        publish { state in
            guard state.degraded, state.identity != nil, state.leased, state.commands != nil else { return nil }
            state.degraded = false
            return .ownerRecovered
        }
    }

    // MARK: Publishing

    fileprivate func publish(_ event: HomeEvent) {
        publish { _ in event }
    }

    /// Builds and yields one event under the lock, so revisions reach every
    /// subscriber in the order they were assigned.
    fileprivate func publish(generation: UInt64? = nil, _ build: (inout State) -> HomeEvent?) {
        state.withLock { state in
            if let generation, state.generation != generation { return }
            guard let event = build(&state) else { return }
            switch event {
            case .connection: state.lastEvent = [event]
            case .inbox: state.lastEvent = state.lastEvent.filter { if case .connection = $0 { true } else { false } } + [event]
            default: break
            }
            for continuation in state.continuations.values { continuation.yield(event) }
        }
    }

    /// An inbox list's revision as the inbox stream seq (UserDO sends
    /// `String(currentSeq)`); nil when it is not one.
    static func revision(_ value: JSONValue?) -> UInt64? {
        switch value {
        case .string(let text): UInt64(text)
        case .number(let number) where number >= 0 && number < 1.8e19 && number.rounded() == number: UInt64(number)
        default: nil
        }
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
}
