import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Subscriptions

    /// Subscribes once per conversation; the least recently used of 64 makes room.
    func subscribe(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) async {
        let sent = state.withLock { state -> Task<Result<CloudSubscription, any Error>, Never>? in
            guard state.generation == generation else { return nil }
            if state.targets[conversation] != nil {
                state.recent.removeAll { $0 == conversation }
                state.recent.append(conversation)
                return nil
            }
            if state.recent.count >= CloudConversationSubscribeRequest.maxSubscriptions {
                let oldest = state.recent.removeFirst()
                state.targets[oldest] = nil
                // Queued with the others, so opening it again at once subscribes after this ends it.
                state.chainUnsubscribes([oldest], commands: commands)
            }
            state.targets[conversation] = CloudHomeState.Target(state: "connecting")
            state.recent.append(conversation)
            return state.chainSubscribe(conversation, commands: commands)
        }
        guard let sent else { return }
        do {
            let reply = try await sent.value.get()
            let live = state.withLock { state -> Bool in
                // A socket on another account's lease is not this account's state.
                if let account = reply.account, state.identity?.cloudID != CloudIdentity.cloudID(stackUserID: account) { return false }
                // The state event that follows the reply (or raced it) wins.
                guard state.generation == generation, state.targets[conversation]?.fromEvent == false else { return false }
                state.targets[conversation]?.state = reply.state
                return reply.state == "live"
            }
            // Edits refused while it connected go again.
            if live { reached() }
        } catch {
            state.withLock { state in
                guard state.generation == generation, state.targets[conversation]?.fromEvent == false else { return }
                state.targets[conversation] = nil
                state.recent.removeAll { $0 == conversation }
            }
        }
    }

    /// An edit goes out only while its conversation's socket is `live`
    /// (home-cloud-proxy.md section 5). Before that it waits
    /// (`ownerUnreachable`: nothing was sent, the store resends it after
    /// `.ownerRecovered`, which a `live` socket publishes), and once the
    /// owner closed the socket it is refused (`notAuthorized`: the user is
    /// not a participant) without subscribing again. A conversation without
    /// a subscription is subscribed first, so its socket can go live and
    /// its echo can settle the intent.
    func requireEditable(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) throws {
        let (target, closed) = state.withLock { ($0.targets[conversation], $0.closed.contains(conversation)) }
        if closed { throw HomeRejection.notAuthorized }
        if target == nil {
            // task-owner: one subscribe; ends with its reply
            Task { [weak self] in await self?.subscribe(conversation, commands: commands, generation: generation) }
        }
        guard target?.state == "live" else {
            state.withLock { $0.degraded = true }
            throw HomeRejection.ownerUnreachable
        }
    }

    /// Ends subscriptions of conversations the inbox no longer lists.
    func unsubscribe(_ ids: [ConversationID], commands: (any CloudConversationCommands)?) {
        guard let commands, !ids.isEmpty else { return }
        state.withLock { $0.chainUnsubscribes(ids, commands: commands) }
    }
}
