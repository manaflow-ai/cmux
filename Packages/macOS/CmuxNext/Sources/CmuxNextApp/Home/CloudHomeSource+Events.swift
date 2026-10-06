import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Synchronization

extension CloudHomeSource {
    fileprivate func apply(_ changed: CloudConversationChanged) {
        let id = ConversationID(changed.conversation)
        publish { state in
            guard let identity = state.identity, known(id, state) else { return nil }
            switch changed.change {
            case .message(let wire), .messageUpdated(let wire):
                let message = CloudHomeMapping.message(wire, identity: identity)
                if var head = state.heads[id] {
                    if message.seq >= head.lastSeq {
                        head.lastSeq = message.seq
                        head.lastMessage = message
                        head.updatedAt = max(head.updatedAt, message.createdAt)
                    }
                    head.rev = max(head.rev, changed.rev)
                    state.heads[id] = head
                }
                return .message(message, rev: changed.rev)
            case .readCursor(let participant, let seq):
                guard mayShow(id, state), var head = state.heads[id] else { return nil }
                let reader = identity.toHome(participant)
                head.readCursors[reader] = max(head.readCursors[reader] ?? 0, seq)
                head.rev = max(head.rev, changed.rev)
                state.heads[id] = head
            case .conversation(let wire):
                guard mayShow(id, state) else { return nil }
                state.heads[id] = CloudHomeMapping.summary(wire, identity: identity)
            case .unknown:
                // An invite delivery report: no Home field changes, but the revision moves.
                guard mayShow(id, state), var head = state.heads[id] else { return nil }
                head.rev = max(head.rev, changed.rev)
                state.heads[id] = head
            }
            guard let summary = joined(id, state) else { return nil }
            return .conversationChanged(summary, stream: .conversation(id), rev: changed.rev)
        }
    }

    fileprivate func apply(_ resynced: CloudConversationResynced) {
        let id = ConversationID(resynced.conversation)
        publish { state in
            // UserDO owns inbox membership: a stream never lists a removed conversation again.
            guard let identity = state.identity, mayShow(id, state) else { return nil }
            let summary = CloudHomeMapping.summary(resynced.summary, identity: identity)
            state.heads[id] = summary
            return .conversationPage(ConversationPage(conversation: joined(id, state) ?? summary,
                                                      messages: resynced.messages.map { CloudHomeMapping.message($0, identity: identity) }))
        }
    }

    /// UserDO's inbox events list conversations the account has not seen
    /// yet, so they are not limited to known ones. A previous account's late
    /// inbox event leaves with the next inbox list (an entry that list does
    /// not have is removed, here and in the router's merged inbox).
    fileprivate func apply(_ changed: CloudInboxChanged) {
        var missing: [ConversationID] = []
        var unlisted: [ConversationID] = []
        var commands: (any CloudConversationCommands)?
        var generation: UInt64 = 0
        for entry in changed.entries {
            let id = ConversationID(entry.conversation)
            publish { state in
                guard state.identity != nil else { return nil }
                state.touched[id] = max(state.touched[id] ?? 0, changed.seq)
                generation = state.generation
                commands = state.commands
                state.inboxRev += 1
                state.created.remove(id)
                guard entry.isListed else {
                    state.entries[id] = nil
                    state.removed.insert(id)
                    if forget(id, &state) { unlisted.append(id) }
                    return .conversationRemoved(id, inboxRev: state.inboxRev)
                }
                state.entries[id] = entry
                state.removed.remove(id)
                state.closed.remove(id)
                if needsHead(id, state) { missing.append(id) }
                return joined(id, state).map { .conversationChanged($0, stream: .inbox, rev: state.inboxRev) }
            }
        }
        unsubscribe(unlisted, commands: commands)
        hydrate(missing, generation: generation)
    }

    fileprivate func apply(_ report: CloudSubscriptionState) {
        // Any socket live again proves the cloud reachable; a disconnect leaves intents waiting for that.
        if report.state == "disconnected" { state.withLock { $0.degraded = true } }
        if report.state == "live" { reached() }
        guard report.scope == "conversation", let conversation = report.conversation else { return }
        let id = ConversationID(conversation)
        state.withLock { state in
            guard state.targets[id] != nil else { return }
            if report.state == "closed" {
                // Forbidden: the user is no longer a participant. The daemon
                // dropped the socket and the inbox removes the conversation.
                state.targets[id] = nil
                state.recent.removeAll { $0 == id }
                state.closed.insert(id)
            } else {
                state.targets[id] = Target(state: report.state, fromEvent: true)
            }
        }
    }

    // MARK: Subscriptions


    /// Subscribes once per conversation; the least recently used of 64 makes room.
    fileprivate func subscribe(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) async {
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
                Self.chainUnsubscribes([oldest], commands: commands, &state)
            }
            state.targets[conversation] = Target(state: "connecting")
            state.recent.append(conversation)
            return Self.chainSubscribe(conversation, commands: commands, &state)
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
    fileprivate func requireEditable(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) throws {
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

    // MARK: Inbox

    fileprivate func reloadInbox(generation: UInt64) async {
        guard state.withLock({ $0.generation == generation }), let inbox = try? await inbox() else { return }
        publish(generation: generation) { _ in .inbox(inbox) }
    }

    fileprivate func publishInbox() {
        publish { state in .inbox(snapshot(&state)) }
    }

    /// Queues a one-message snapshot read for each listed conversation
    /// without a current head and publishes its summary. One queue serves
    /// the whole source, so at most `hydrationWidth` reads use the daemon's
    /// request budget at once, and a conversation waits in it only once.
}
