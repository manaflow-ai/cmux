import Foundation

// WireHomeSource's ops: each HomeOp as the owner's `POST /v1/ops` body, the
// same params the daemon forwards (CloudConversationOp, contract.rs
// `op_body` and `inbox_op_body`). The intent's key is the op's
// idempotency key, so the store's resend after a lost answer replays.
extension WireHomeSource {
    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        guard !stopped else { throw HomeRejection.ownerUnreachable }
        if case .setTyping(let conversation, let on) = intent.op {
            // Ephemeral: sent once on the open conversation's socket, never stored or resent.
            _ = await conversationStreams[conversation]?.sendTyping(on)
            return HomeOpResult(rev: 0, conversation: conversation)
        }
        guard let me else { throw HomeRejection.ownerUnreachable }
        let key = intent.key
        switch intent.op {
        case .sendMessage(let conversation, let parts, let threadRoot, let parent):
            // message.send needs client_msg_id == idempotency_key. `thread_root` is the
            // thread; `reply_to` the message answered (the root when `parent` is nil).
            var params: [String: HomeWireJSON] = ["client_msg_id": .string(key.rawValue), "parts": mapping.wire(parts)]
            if let threadRoot {
                params["reply_to"] = ["message_id": .string((parent ?? threadRoot).rawValue), "part_index": 0]
                params["thread_root"] = .string(threadRoot.rawValue)
            }
            return try await conversationOp("message.send", params, in: conversation, key: key)
        case .editMessage(let message, let conversation, let parts):
            return try await conversationOp("message.edit", ["message_id": .string(message.rawValue), "parts": mapping.wire(parts)],
                                            in: conversation, key: key)
        case .retractMessage(let message, let conversation):
            return try await conversationOp("message.retract", ["message_id": .string(message.rawValue)], in: conversation, key: key)
        case .addReaction(let message, let conversation, let reaction, let partIndex):
            return try await conversationOp("reaction.add", reactionParams(message, reaction, partIndex), in: conversation, key: key)
        case .removeReaction(let message, let conversation, let reaction, let partIndex):
            return try await conversationOp("reaction.remove", reactionParams(message, reaction, partIndex), in: conversation, key: key)
        case .setReadCursor(let conversation, let seq):
            return try await conversationOp("read_cursor.set", ["seq": .uint(seq)], in: conversation, key: key)
        case .renameConversation(let conversation, let title):
            return try await conversationOp("title.set", ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines))],
                                            in: conversation, key: key)
        case .setChiefReplies(let conversation, let policy):
            return try await conversationOp("conversation.settings.set", ["wake_policy": .string(policy.rawValue)],
                                            in: conversation, key: key)
        case .updateThread(let conversation, let root, let title, let status, let owner):
            var params: [String: HomeWireJSON] = ["root": .string(root.rawValue)]
            if let title { params["title"] = .string(title) }
            if let status { params["status"] = .string(status.rawValue) }
            if let owner { params["owner"] = .string(owner) }
            return try await conversationOp("thread.update", params, in: conversation, key: key)
        case .addParticipants(let conversation, let ids):
            let records = ids.filter { $0 != me.id }.map(participantRecord)
            guard !records.isEmpty else { throw HomeRejection.invalid("invalid_participant") }
            // One participants.add per person; a single add keeps the intent's key, several
            // derive theirs from it, so a resend replays each one that committed.
            var last = HomeOpResult(rev: 0, conversation: conversation)
            for (index, record) in records.enumerated() {
                last = try await conversationOp("participants.add", ["participant": record], in: conversation,
                                                key: records.count == 1 ? key : IdempotencyKey("\(key.rawValue):add:\(index)"))
            }
            return last
        case .removeParticipant(let conversation, let participant):
            return try await conversationOp("participants.remove", ["participant": .string(participant.rawValue)],
                                            in: conversation, key: key)
        case .createGroup(let title, let ids, let invites):
            var params: [String: HomeWireJSON] = [
                "participants": .array([participantRecord(me.id)] + ids.filter { $0 != me.id }.map(participantRecord)),
            ]
            if !title.isEmpty { params["title"] = .string(title) }
            let (value, replayed) = try await client.op("conversation.create", .object(params), key: key)
            let conversation = try opened(value)
            // People and addresses in one New Message: each address joins the group as invited.
            for (index, contact) in invites.enumerated() {
                _ = try await conversationOp("invite.create", ["address": address(contact), "display_name": .string(Self.masked(contact))],
                                             in: conversation, key: IdempotencyKey("\(key.rawValue):invite:\(index)"))
            }
            return HomeOpResult(rev: 0, replayed: replayed, conversation: conversation)
        case .openDirect(let peer):
            let (value, replayed) = try await client.op("dm.open", ["peer": .string(peer.rawValue)], key: key)
            return HomeOpResult(rev: 0, replayed: replayed, conversation: try opened(value))
        case .invite(let contact):
            return try await openDirect(with: contact, firstMessage: [], key: key)
        case .startConversation(let contacts, let firstMessage):
            guard let first = contacts.first else { throw HomeRejection.invalid("invalid_participant") }
            guard contacts.count > 1 else { return try await openDirect(with: first, firstMessage: firstMessage, key: key) }
            // A group of addresses: create it with the user, then invite each address.
            let (value, replayed) = try await client.op("conversation.create", ["participants": [participantRecord(me.id)]], key: key)
            let conversation = try opened(value)
            for (index, contact) in contacts.enumerated() {
                _ = try await conversationOp("invite.create", ["address": address(contact), "display_name": .string(Self.masked(contact))],
                                             in: conversation, key: IdempotencyKey("\(key.rawValue):invite:\(index)"))
            }
            try await sendFirst(firstMessage, in: conversation, key: key)
            return HomeOpResult(rev: 0, replayed: replayed, conversation: conversation,
                                invite: InviteReceipt(contact: first, channel: first.isEmail ? .email : .sms, alreadyMember: false))
        case .setPinned(let conversation, let rank):
            var params: [String: HomeWireJSON] = ["pinned": .bool(rank != nil)]
            if let rank { params["position"] = .number(Double(rank)) }
            return try await inboxOp("inbox.pin", params, in: conversation, key: key) { entry in
                entry["pinned"] = .bool(rank != nil)
                entry["pin_position"] = rank.map { .number(Double($0)) } ?? .null
            }
        case .setMuted(let conversation, let muted):
            return try await inboxOp("inbox.mute", ["muted": .bool(muted)], in: conversation, key: key) { entry in
                entry["muted"] = .bool(muted)
            }
        case .createChief, .answerQuestion:
            // chief.create and question.answer belong to the Chief's owner, not to this source.
            throw HomeRejection.invalid("unsupported_op")
        case .setTyping:
            return HomeOpResult(rev: 0)
        }
    }

    // MARK: Helpers

    /// One op on a conversation's owner; its result's rev is the head's.
    private func conversationOp(_ op: String, _ params: [String: HomeWireJSON], in conversation: ConversationID,
                                key: IdempotencyKey) async throws -> HomeOpResult {
        try Self.requireConversationID(conversation)
        var params = params
        params["conversation"] = .string(conversation.rawValue)
        let (value, replayed) = try await client.op(op, .object(params), key: key)
        return HomeOpResult(rev: value["rev"].uint ?? 0, replayed: replayed, conversation: conversation)
    }

    /// One op on the user's own inbox entry (`inbox.pin`, `inbox.mute`; no
    /// origin). The entry changes here at once, at a new inbox revision the
    /// result names, so the store settles it; the inbox stream's own event
    /// comes after and repeats it.
    private func inboxOp(_ op: String, _ params: [String: HomeWireJSON], in conversation: ConversationID, key: IdempotencyKey,
                         change: (inout [String: HomeWireJSON]) -> Void) async throws -> HomeOpResult {
        try Self.requireConversationID(conversation)
        var params = params
        params["conversation"] = .string(conversation.rawValue)
        let (value, replayed) = try await client.op(op, .object(params), key: key, origin: nil)
        var entry = value["entry"].object ?? entries[conversation]?.object ?? ["conversation": .string(conversation.rawValue)]
        if value["entry"].object == nil { change(&entry) }
        entries[conversation] = .object(entry)
        inboxRev += 1
        if let summary = joined(conversation) { publish(.conversationChanged(summary, stream: .inbox, rev: inboxRev)) }
        return HomeOpResult(rev: inboxRev, replayed: replayed, conversation: conversation)
    }

    private func reactionParams(_ message: MessageID, _ reaction: Reaction.Kind, _ partIndex: Int) -> [String: HomeWireJSON] {
        ["message_id": .string(message.rawValue), "part_index": .number(Double(partIndex)), "reaction": mapping.wire(reaction)]
    }

    /// `dm.open` with an address (an invite when nobody has it), then the first message.
    private func openDirect(with contact: ContactAddress, firstMessage: [MessagePart], key: IdempotencyKey) async throws -> HomeOpResult {
        let (value, replayed) = try await client.op("dm.open", ["peer": address(contact)], key: key)
        let conversation = try opened(value)
        try await sendFirst(firstMessage, in: conversation, key: key)
        let invited = value["invite"]["ok"].bool == true
        return HomeOpResult(rev: 0, replayed: replayed, conversation: conversation,
                            invite: invited ? InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: false) : nil)
    }

    /// The first message of a new conversation, keyed from the intent so a resend replays it.
    private func sendFirst(_ parts: [MessagePart], in conversation: ConversationID, key: IdempotencyKey) async throws {
        guard !parts.isEmpty else { return }
        let messageKey = IdempotencyKey("\(key.rawValue):message")
        _ = try await conversationOp("message.send", ["client_msg_id": .string(messageKey.rawValue), "parts": mapping.wire(parts)],
                                     in: conversation, key: messageKey)
    }

    /// The conversation a `dm.open` or `conversation.create` answered, published at once.
    private func opened(_ value: HomeWireJSON) throws -> ConversationID {
        guard let summary = mapping.summary(value["conversation"]) else { throw HomeRejection.indeterminate }
        if let known = heads[summary.id], known.rev > summary.rev {} else { heads[summary.id] = summary }
        if entries[summary.id] == nil { created.insert(summary.id) }
        inboxRev += 1
        publish(.conversationChanged(joined(summary.id) ?? summary, stream: .inbox, rev: inboxRev))
        return summary.id
    }

    /// A participant record for `conversation.create` and `participants.add`:
    /// the name this source knows from any head, else none.
    private func participantRecord(_ id: ParticipantID) -> HomeWireJSON {
        let known = id == me?.id ? me : heads.values.lazy.flatMap(\.participants).first { $0.id == id }
        let isAgent = known.map { $0.kind == .agent } ?? id.rawValue.hasPrefix("agent_")
        var record: [String: HomeWireJSON] = [
            "id": .string(id.rawValue), "kind": .string(isAgent ? "agent" : "human"),
            "display_name": .string(known?.displayName ?? ""),
        ]
        if isAgent { record["agent_class"] = .string(known?.agentClass == .chief ? "mux" : "agent") }
        return .object(record)
    }

    private func address(_ contact: ContactAddress) -> HomeWireJSON {
        switch contact {
        case .email(let value): ["email": .string(value)]
        case .phone(let value): ["phone": .string(value)]
        }
    }

    /// The masked form the Worker shows for an address (home-core `maskAddress`).
    static func masked(_ contact: ContactAddress) -> String {
        switch contact {
        case .email(let value):
            let pieces = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return "***" }
            return "\(pieces[0].prefix(1))***@\(pieces[1])"
        case .phone(let value):
            let digits = value.dropFirst()
            guard value.hasPrefix("+"), (11...15).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }) else { return "***" }
            return "+\(digits.dropLast(10)) *** *** \(value.suffix(4))"
        }
    }
}
