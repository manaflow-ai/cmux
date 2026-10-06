import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Synchronization

extension CloudHomeSource {
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        let (commands, identity, _) = try requireEndpoint()
        let page = try await reply(for: identity) { try await commands.history(conversation.rawValue, before: beforeSeq, limit: limit) }
        return page.messages.map { CloudHomeMapping.message($0, identity: identity) }
    }

    /// Binds the intent's key to the signed-in account first: a key a
    /// previous account submitted is refused (`notAuthorized`, the store
    /// drops it) and never reaches the daemon under this account's lease.
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        if case .setTyping(let conversation, _) = intent.op {
            // Typing is not in cloud-conversations-v1 part 1: nothing is sent or
            // resent, so the key is not bound to the account.
            return HomeOpResult(rev: 0, conversation: conversation)
        }
        let key = intent.key.rawValue
        let (commands, identity, generation) = try requireEndpoint(binding: key)
        let result: HomeOpResult
        do {
            result = try await run(intent, commands: commands, identity: identity, generation: generation)
        } catch let rejection as HomeRejection {
            // Refused for good: the store never resends it. A refused send stays
            // bound, because the user may send it again with the same key.
            if Self.isFinal(rejection), !Self.isSend(intent.op) { state.withLock { _ = $0.accepted.remove(key) } }
            throw rejection
        }
        // Committed: the store never sends this key again.
        state.withLock { _ = $0.accepted.remove(key) }
        return result
    }

    fileprivate static func isSend(_ op: HomeOp) -> Bool {
        if case .sendMessage = op { true } else { false }
    }

    /// A refusal the store does not resend.
    fileprivate static func isFinal(_ rejection: HomeRejection) -> Bool {
        switch rejection {
        case .invalid, .notAuthorized: true
        default: false
        }
    }

    fileprivate func run(_ intent: HomeIntent, commands: any CloudConversationCommands, identity: CloudIdentity,
                     generation: UInt64) async throws -> HomeOpResult {
        let key = intent.key.rawValue
        func send(_ op: CloudConversationOp, in conversation: ConversationID?, key: String = key) async throws -> CloudConversationOpResult {
            let request = CloudConversationOpRequest(conversation: conversation?.rawValue, idempotencyKey: key, origin: "user", op: op)
            return try await reply(for: identity) { try await commands.op(request) }
        }
        func edit(_ op: CloudConversationOp, in conversation: ConversationID) async throws -> HomeOpResult {
            beginEdit(conversation, generation: generation)
            let result: CloudConversationOpResult
            do {
                try requireEditable(conversation, commands: commands, generation: generation)
                result = try await send(op, in: conversation)
            } catch {
                // A resend follows a transient failure and needs the socket
                // live; one refused for good waits for nothing.
                let final = (error as? HomeRejection).map(Self.isFinal) ?? false
                finishEdit(conversation, generation: generation, committedAt: nil, final: final)
                throw error
            }
            finishEdit(conversation, generation: generation, committedAt: result.rev ?? 0, final: false)
            return HomeOpResult(rev: result.rev ?? 0, replayed: result.replayed, conversation: conversation)
        }
        switch intent.op {
        case .sendMessage(let conversation, let parts):
            // The owner's message.send key must equal client_msg_id.
            return try await edit(.send(clientMsgID: key, parts: CloudHomeMapping.parts(parts, identity: identity), replyTo: nil),
                                  in: conversation)
        case .setReadCursor(let conversation, let seq):
            return try await edit(.setReadCursor(seq: seq), in: conversation)
        case .addReaction(let message, let conversation, let reaction, let partIndex):
            return try await edit(.addReaction(messageID: message.rawValue, partIndex: partIndex,
                                               kind: CloudHomeMapping.reaction(reaction)), in: conversation)
        case .setTyping(let conversation, _):
            // Answered by `submit` before binding; nothing to send.
            return HomeOpResult(rev: 0, conversation: conversation)
        case .setPinned, .setMuted, .createChief:
            // inbox.pin, inbox.mute and chief.create are not cloud-conversation-op kinds yet
            // (home-cloud-proxy.md section 8); refused here exactly as the daemon would.
            throw HomeRejection.invalid("unsupported_op")
        case .createGroup(let title, let ids):
            let participants = [identity.participant] + state.withLock { state in
                ids.filter { $0 != identity.localID }.map { participantRecord($0, identity: identity, state) }
            }
            let result = try await send(.create(title: title.isEmpty ? nil : title, participants: participants), in: nil)
            let created = try opened(result, identity: identity, generation: generation)
            return HomeOpResult(rev: 0, replayed: result.replayed, conversation: created)
        case .invite(let contact):
            return try await openDM(with: contact, firstMessage: [], key: key, identity: identity, generation: generation, send: send)
        case .startConversation(let contacts, let firstMessage):
            guard let first = contacts.first else { throw HomeRejection.invalid("invalid_participant") }
            guard contacts.count > 1 else {
                return try await openDM(with: first, firstMessage: firstMessage, key: key, identity: identity,
                                        generation: generation, send: send)
            }
            // A group of addresses: create it with the user, then invite each address.
            let result = try await send(.create(title: nil, participants: [identity.participant]), in: nil)
            let created = try opened(result, identity: identity, generation: generation)
            for (index, contact) in contacts.enumerated() {
                _ = try await send(.createInvite(address: CloudHomeMapping.address(contact), displayName: Self.masked(contact), locale: nil),
                                   in: created, key: "\(key):invite:\(index)")
            }
            try await sendFirst(firstMessage, in: created, key: key, identity: identity, send: send)
            return HomeOpResult(rev: 0, replayed: result.replayed, conversation: created,
                                invite: InviteReceipt(contact: first, channel: first.isEmail ? .email : .sms, alreadyMember: false))
        }
    }

    /// The transcript left the screen ("open" means on screen now): its
    /// subscription ends, and a conversation the inbox does not list (one
    /// opened from the archive, a deep link or a notification) leaves the
    /// inbox. A listed one stays as UserDO lists it.
    func close(_ conversation: ConversationID) {
        var ending: (any CloudConversationCommands)?
        publish { state in
            state.viewed.remove(conversation)
            // The close ends the subscription an edit kept, too.
            state.editHolds.removeValue(forKey: conversation)?.deadline.cancel()
            guard state.targets.removeValue(forKey: conversation) != nil else { return nil }
            state.recent.removeAll { $0 == conversation }
            ending = state.commands
            guard state.entries[conversation] == nil, !state.created.contains(conversation) else { return nil }
            state.heads[conversation] = nil
            state.inboxRev += 1
            return .conversationRemoved(conversation, inboxRev: state.inboxRev)
        }
        unsubscribe([conversation], commands: ending)
    }

    /// Home search is not in cloud-conversations-v1 part 1.
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }

    /// `dm.open` resolves addresses on the owner and answers the same whether
    /// or not the address has an account, so the client cannot tell.
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }

    // MARK: Ops

    fileprivate func openDM(with contact: ContactAddress, firstMessage: [MessagePart], key: String, identity: CloudIdentity,
                        generation: UInt64,
                        send: (CloudConversationOp, ConversationID?, String) async throws -> CloudConversationOpResult) async throws -> HomeOpResult {
        let result = try await send(.dmOpen(peer: .address(CloudHomeMapping.address(contact))), nil, key)
        let conversation = try opened(result, identity: identity, generation: generation)
        try await sendFirst(firstMessage, in: conversation, key: key, identity: identity, send: send)
        let invited = result.invite?.ok == true
        return HomeOpResult(rev: 0, replayed: result.replayed, conversation: conversation,
                            invite: invited ? InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: false) : nil)
    }

    /// The first message of a new conversation, keyed from the intent so a resend replays it.
    fileprivate func sendFirst(_ parts: [MessagePart], in conversation: ConversationID, key: String, identity: CloudIdentity,
                           send: (CloudConversationOp, ConversationID?, String) async throws -> CloudConversationOpResult) async throws {
        guard !parts.isEmpty else { return }
        let messageKey = "\(key):message"
        _ = try await send(.send(clientMsgID: messageKey, parts: CloudHomeMapping.parts(parts, identity: identity), replyTo: nil),
                           conversation, messageKey)
    }

    /// The conversation a `dm.open` or `conversation.create` answered, published at once.
    fileprivate func opened(_ result: CloudConversationOpResult, identity: CloudIdentity, generation: UInt64) throws -> ConversationID {
        guard let wire = result.conversation else { throw HomeRejection.indeterminate }
        let summary = CloudHomeMapping.summary(wire, identity: identity)
        publish(generation: generation) { state in
            state.heads[summary.id] = summary
            if state.entries[summary.id] == nil { state.created.insert(summary.id) }
            state.inboxRev += 1
            return .conversationChanged(joined(summary.id, state) ?? summary, stream: .inbox, rev: state.inboxRev)
        }
        return summary.id
    }

    /// The masked form the Worker shows for an address (home-core `maskAddress`).
    static func masked(_ contact: ContactAddress) -> String {
        switch contact {
        case .email(let value):
            let pieces = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return "***" }
            return "\(pieces[0].prefix(1))***@\(pieces[1])"
        case .phone(let value):
            // E.164 with a country code and ten national digits at least, so
            // the last four never show most of the number; anything else shows nothing.
            let digits = value.dropFirst()
            guard value.hasPrefix("+"), (11...15).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }) else { return "***" }
            return "+\(digits.dropLast(10)) *** *** \(value.suffix(4))"
        }
    }

    // MARK: Events
}
