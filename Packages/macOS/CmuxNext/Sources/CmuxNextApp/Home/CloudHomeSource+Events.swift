import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Events

    func apply(_ changed: CloudConversationChanged) {
        let id = ConversationID(changed.conversation)
        publish { state in
            guard let identity = state.identity, state.known(id) else { return nil }
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
                guard state.mayShow(id), var head = state.heads[id] else { return nil }
                let reader = identity.toHome(participant)
                head.readCursors[reader] = max(head.readCursors[reader] ?? 0, seq)
                head.rev = max(head.rev, changed.rev)
                state.heads[id] = head
            case .conversation(let wire):
                guard state.mayShow(id) else { return nil }
                state.heads[id] = CloudHomeMapping.summary(wire, identity: identity)
            case .unknown:
                // An invite delivery report: no Home field changes, but the revision moves.
                guard state.mayShow(id), var head = state.heads[id] else { return nil }
                head.rev = max(head.rev, changed.rev)
                state.heads[id] = head
            }
            guard let summary = state.joined(id) else { return nil }
            return .conversationChanged(summary, stream: .conversation(id), rev: changed.rev)
        }
    }

    func apply(_ resynced: CloudConversationResynced) {
        let id = ConversationID(resynced.conversation)
        publish { state in
            // UserDO owns inbox membership: a stream never lists a removed conversation again.
            guard let identity = state.identity, state.mayShow(id) else { return nil }
            let summary = CloudHomeMapping.summary(resynced.summary, identity: identity)
            state.heads[id] = summary
            return .conversationPage(ConversationPage(conversation: state.joined(id) ?? summary,
                                                      messages: resynced.messages.map { CloudHomeMapping.message($0, identity: identity) }))
        }
    }

    /// UserDO's inbox events list conversations the account has not seen
    /// yet, so they are not limited to known ones. A previous account's late
    /// inbox event leaves with the next inbox list (an entry that list does
    /// not have is removed, here and in the router's merged inbox).
    func apply(_ changed: CloudInboxChanged) {
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
                    if state.forget(id) { unlisted.append(id) }
                    return .conversationRemoved(id, inboxRev: state.inboxRev)
                }
                state.entries[id] = entry
                state.removed.remove(id)
                state.closed.remove(id)
                if state.needsHead(id) { missing.append(id) }
                return state.joined(id).map { .conversationChanged($0, stream: .inbox, rev: state.inboxRev) }
            }
        }
        unsubscribe(unlisted, commands: commands)
        hydrate(missing, generation: generation)
    }

    func apply(_ report: CloudSubscriptionState) {
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
                state.targets[id] = CloudHomeState.Target(state: report.state, fromEvent: true)
            }
        }
    }
}
