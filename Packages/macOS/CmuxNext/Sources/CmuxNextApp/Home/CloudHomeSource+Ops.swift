import CmuxHomeCore
import CmuxNextDaemon
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Ops

    func run(_ intent: HomeIntent, commands: any CloudConversationCommands, identity: CloudIdentity,
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
                ids.filter { $0 != identity.localID }.map { state.participantRecord($0, identity: identity) }
            }
            let result = try await send(.create(title: title.isEmpty ? nil : title, participants: participants), in: nil)
            let created = try opened(result, identity: identity, generation: generation)
            return HomeOpResult(rev: 0, replayed: result.replayed, conversation: created)
        case .openDirect(let peer):
            let result = try await send(.dmOpen(peer: .participant(identity.toCloud(peer))), in: nil)
            let conversation = try opened(result, identity: identity, generation: generation)
            return HomeOpResult(rev: 0, replayed: result.replayed, conversation: conversation)
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

    private func openDM(with contact: ContactAddress, firstMessage: [MessagePart], key: String, identity: CloudIdentity,
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
    private func sendFirst(_ parts: [MessagePart], in conversation: ConversationID, key: String, identity: CloudIdentity,
                           send: (CloudConversationOp, ConversationID?, String) async throws -> CloudConversationOpResult) async throws {
        guard !parts.isEmpty else { return }
        let messageKey = "\(key):message"
        _ = try await send(.send(clientMsgID: messageKey, parts: CloudHomeMapping.parts(parts, identity: identity), replyTo: nil),
                           conversation, messageKey)
    }

    /// The conversation a `dm.open` or `conversation.create` answered, published at once.
    private func opened(_ result: CloudConversationOpResult, identity: CloudIdentity, generation: UInt64) throws -> ConversationID {
        guard let wire = result.conversation else { throw HomeRejection.indeterminate }
        let summary = CloudHomeMapping.summary(wire, identity: identity)
        publish(generation: generation) { state in
            state.heads[summary.id] = summary
            if state.entries[summary.id] == nil { state.created.insert(summary.id) }
            state.inboxRev += 1
            return .conversationChanged(state.joined(summary.id) ?? summary, stream: .inbox, rev: state.inboxRev)
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

    /// The transport and account for a read, or for an intent whose key
    /// `binding` names: that key now belongs to this account, unless a
    /// previous account submitted it. Without the daemon's lease for this
    /// account nothing goes out (a reply could be another account's): the
    /// refusal waits (`ownerUnreachable`) and asks the link for a lease.
    func requireEndpoint(binding key: String? = nil) throws -> (any CloudConversationCommands, CloudIdentity, UInt64) {
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
}
