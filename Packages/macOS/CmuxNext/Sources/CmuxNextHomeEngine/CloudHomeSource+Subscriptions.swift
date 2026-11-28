import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Subscriptions

    // The decisions are the Rust rules' (`cloud.subs_*`, cmux-home-rules
    // `cloud/subscriptions.rs`); the lock, the daemon calls and `reached()` stay here.

    /// Subscribes once per conversation; the least recently used of 64 makes room.
    func subscribe(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) async {
        let sent = state.withLock { state -> Task<Result<CloudSubscription, any Error>, Never>? in
            let request = SubsSubscribeRequest(state: SubsState(state), conversation: conversation.rawValue, generation: generation,
                                               max: CloudConversationSubscribeRequest.maxSubscriptions)
            guard let reply: SubsSubscribeReply = try? HomeRules.call("cloud.subs_subscribe", request) else { return nil }
            reply.state.apply(to: &state)
            // Queued with the others, so opening it again at once subscribes after this ends it.
            if !reply.unsubscribe.isEmpty { state.chainUnsubscribes(reply.unsubscribe.map(ConversationID.init(rawValue:)), commands: commands) }
            return reply.subscribe ? state.chainSubscribe(conversation, commands: commands) : nil
        }
        guard let sent else { return }
        do {
            let reply = try await sent.value.get()
            let live = state.withLock { state -> Bool in
                // A socket on another account's lease is not this account's state; the state
                // event that follows the reply (or raced it) wins.
                let request = SubsRepliedRequest(state: SubsState(state), conversation: conversation.rawValue, generation: generation,
                                                 replyState: reply.state, account: reply.account, identityCloudId: state.identity?.cloudID)
                guard let replied: SubsRepliedReply = try? HomeRules.call("cloud.subs_replied", request) else { return false }
                replied.state.apply(to: &state)
                return replied.live
            }
            // Edits refused while it connected go again.
            if live { reached() }
        } catch {
            state.withLock { state in
                let request = SubsFailedRequest(state: SubsState(state), conversation: conversation.rawValue, generation: generation)
                guard let subs: SubsState = try? HomeRules.call("cloud.subs_failed", request) else { return }
                subs.apply(to: &state)
            }
        }
    }

    /// An edit goes out only while its conversation's socket is `live`
    /// (home-cloud-proxy.md section 5). Before that it waits (`ownerUnreachable`;
    /// the store resends after the `.ownerRecovered` a `live` socket publishes,
    /// so `degraded` is set in the read's lock, before the subscribe can go live),
    /// and once the owner closed the socket it is refused (`notAuthorized`)
    /// without subscribing again. A conversation without a subscription is
    /// subscribed first, so its socket can go live and its echo can settle the intent.
    func requireEditable(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) throws {
        let editable = state.withLock { state -> SubsEditable? in
            let request = SubsEditableRequest(target: state.targets[conversation]?.state, closed: state.closed.contains(conversation))
            guard let editable: SubsEditable = try? HomeRules.call("cloud.subs_editable", request) else { return nil }
            if editable.degraded { state.degraded = true }
            return editable
        }
        // No answer from the rules: the edit waits, as for a socket not live yet.
        guard let editable else { throw HomeRejection.ownerUnreachable }
        if editable.subscribe {
            // task-owner: one subscribe; ends with its reply
            Task { [weak self] in await self?.subscribe(conversation, commands: commands, generation: generation) }
        }
        switch editable.error {
        case nil: return
        case "notAuthorized": throw HomeRejection.notAuthorized
        default: throw HomeRejection.ownerUnreachable
        }
    }

    /// Ends subscriptions of conversations the inbox no longer lists.
    func unsubscribe(_ ids: [ConversationID], commands: (any CloudConversationCommands)?) {
        guard let commands, !ids.isEmpty else { return }
        state.withLock { $0.chainUnsubscribes(ids, commands: commands) }
    }
}

/// The subscription part of `CloudHomeState` on the `cloud.subs_*` wire.
private nonisolated struct SubsState: Codable {
    struct Target: Codable {
        var state: String
        var fromEvent: Bool
    }

    var generation: UInt64
    var targets: [String: Target]
    var recent: [String]

    init(_ state: CloudHomeState) {
        generation = state.generation
        targets = Dictionary(uniqueKeysWithValues: state.targets.map { ($0.key.rawValue, Target(state: $0.value.state, fromEvent: $0.value.fromEvent)) })
        recent = state.recent.map(\.rawValue)
    }

    func apply(to state: inout CloudHomeState) {
        state.targets = Dictionary(uniqueKeysWithValues: targets.map {
            (ConversationID(rawValue: $0.key), CloudHomeState.Target(state: $0.value.state, fromEvent: $0.value.fromEvent))
        })
        state.recent = recent.map(ConversationID.init(rawValue:))
    }
}

private nonisolated struct SubsSubscribeRequest: Encodable {
    var state: SubsState
    var conversation: String
    var generation: UInt64
    var max: Int
}

private nonisolated struct SubsSubscribeReply: Decodable {
    var state: SubsState
    var subscribe: Bool
    var unsubscribe: [String]
}

private nonisolated struct SubsRepliedRequest: Encodable {
    var state: SubsState
    var conversation: String
    var generation: UInt64
    var replyState: String
    var account: String?
    var identityCloudId: String?
}

private nonisolated struct SubsRepliedReply: Decodable {
    var state: SubsState
    var live: Bool
}

private nonisolated struct SubsFailedRequest: Encodable {
    var state: SubsState
    var conversation: String
    var generation: UInt64
}

private nonisolated struct SubsEditableRequest: Encodable {
    var target: String?
    var closed: Bool
}

private nonisolated struct SubsEditable: Decodable {
    var degraded: Bool
    var subscribe: Bool
    var error: String?
}
