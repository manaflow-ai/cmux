public import CmuxAgentQuestion
public import CmuxHomeCore
import Foundation

// Home ops: one entry point that applies each idempotency key once.
extension ChiefConversationOwner {
    /// Applies an intent, at most once per key.
    ///
    /// A key already decided answers its stored result with `replayed` set;
    /// the same key with another op is refused `idempotency_conflict`. A send
    /// whose client id already committed (before a relaunch) answers replayed.
    ///
    /// - Parameter intent: The op and its key.
    /// - Returns: The revision of the op's stream after the commit.
    /// - Throws: ``HomeRejection`` when the op is refused.
    @discardableResult
    public func submit(_ intent: HomeIntent) throws -> HomeOpResult {
        if let decided = ledger[intent.key] {
            guard decided.op == intent.op else { throw HomeRejection.invalid("idempotency_conflict") }
            var replay = decided.result
            replay.replayed = true
            return replay
        }
        if case .sendMessage(let id, _, _) = intent.op, let state = conversations[id],
           state.message(clientID: intent.key) != nil {
            return HomeOpResult(rev: state.summary.rev, replayed: true, conversation: id)
        }
        let result = try apply(intent)
        if case .setTyping = intent.op {} else { ledger[intent.key] = (intent.op, result) }
        return result
    }

    private func apply(_ intent: HomeIntent) throws -> HomeOpResult {
        switch intent.op {
        case .sendMessage(let id, let parts, let threadRoot):
            return try send(parts, in: id, threadRoot: threadRoot, key: intent.key)
        case .editMessage(let messageID, let id, let parts):
            guard !parts.isEmpty else { throw HomeRejection.invalid("invalid_parts") }
            return try updateOwnMessage(messageID, in: id) {
                $0.parts = parts
                $0.editedAt = now()
            }
        case .retractMessage(let messageID, let id):
            return try updateOwnMessage(messageID, in: id) {
                $0.parts = []
                $0.retractedAt = now()
            }
        case .setReadCursor(let id, let seq):
            let state = try conversationState(id)
            guard seq <= state.summary.lastSeq else { throw HomeRejection.invalid("cursor_beyond_end") }
            moveReadCursor(id, of: me.id, to: seq)
            return HomeOpResult(rev: conversations[id]?.summary.rev ?? state.summary.rev)
        case .addReaction(let messageID, let id, let kind, let partIndex):
            let reaction = Reaction(author: me.id, partIndex: partIndex, kind: kind)
            let message = try updateMessage(messageID, in: id) {
                if !$0.reactions.contains(reaction) { $0.reactions.append(reaction) }
            }
            return HomeOpResult(rev: try conversationState(message.conversation).summary.rev)
        case .removeReaction(let messageID, let id, let kind, let partIndex):
            let reaction = Reaction(author: me.id, partIndex: partIndex, kind: kind)
            try updateMessage(messageID, in: id) { $0.reactions.removeAll { $0 == reaction } }
            return HomeOpResult(rev: try conversationState(id).summary.rev)
        case .setPinned(let id, let rank):
            return try updateInbox(id) { $0.pinRank = rank }
        case .setMuted(let id, let muted):
            return try updateInbox(id) { $0.muted = muted }
        case .createChief(let name):
            return try createChief(name: name)
        case .answerQuestion(let messageID, let id, let partIndex, let answer):
            return try answerQuestion(messageID, in: id, partIndex: partIndex, answer: answer)
        case .setTyping(let id, _):
            // The Chief does not watch the user type; nothing to publish.
            return HomeOpResult(rev: try conversationState(id).summary.rev)
        case .createGroup, .startConversation, .invite, .openDirect:
            throw HomeRejection.invalid("unsupported")
        }
    }

    private func send(_ parts: [MessagePart], in id: ConversationID, threadRoot: MessageID?,
                      key: IdempotencyKey) throws -> HomeOpResult {
        let state = try conversationState(id)
        let text = parts.map(\.plainText).joined()
        guard !parts.isEmpty, !text.isEmpty, text.utf8.count <= 65_536 else { throw HomeRejection.invalid("invalid_parts") }
        var images: [URL] = []
        var notes: [String] = []
        for case .attachment(let ref) in parts {
            guard let file = blobs.file(ref.hash) else { throw HomeRejection.invalid("unknown_attachment") }
            if ref.mimeType.lowercased().hasPrefix("image/") {
                images.append(file)
            } else {
                notes.append("[Attached file: \(ref.name) (\(ref.mimeType)) at \(file.path)]")
            }
        }
        var replyContext: String?
        if let threadRoot {
            guard let root = state.message(threadRoot), root.threadRoot == nil else {
                throw HomeRejection.invalid("unknown_reply_target")
            }
            replyContext = root.plainText
        }
        let message = try commitMessage(in: id, author: me.id, parts: parts, key: key, threadRoot: threadRoot)
        let rev = try self.conversationState(id).summary.rev
        let typed = parts.compactMap { part -> String? in
            if case .text(let value, _) = part { return value }
            return nil
        }
        let userText = (typed + notes).joined(separator: "\n\n")
        enqueue(ChiefPendingTurn(readSeq: message.seq, text: userText, attachmentPaths: images, replyContext: replyContext,
                                 threadRoot: threadRoot), in: id)
        return HomeOpResult(rev: rev, conversation: id)
    }

    /// Only the user changes their own message, and a retracted one stays retracted.
    private func updateOwnMessage(_ messageID: MessageID, in id: ConversationID,
                                  _ change: (inout Message) -> Void) throws -> HomeOpResult {
        try updateMessage(messageID, in: id) { message in
            guard message.author == me.id else { throw HomeRejection.notAuthorized }
            guard message.retractedAt == nil else { throw HomeRejection.invalid("message_retracted") }
            change(&message)
        }
        return HomeOpResult(rev: try conversationState(id).summary.rev)
    }

    /// Makes a new Chief with its own conversation (and its own brain session).
    private func createChief(name: String) throws -> HomeOpResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { throw HomeRejection.invalid("invalid_name") }
        let suffix = Self.mintSuffix(12)
        let agent = Participant(id: ParticipantID("agent_chief_\(suffix)"), kind: .agent, displayName: trimmed,
                                agentClass: .chief, ownerUser: me.id)
        let created = now()
        let summary = ConversationSummary(id: ConversationID("conv_\(suffix)"), owner: .local, participants: [me, agent],
                                          createdAt: created, updatedAt: created)
        insertConversation(summary)
        return HomeOpResult(rev: inboxRev, conversation: summary.id)
    }

    /// Records the answer on the question part, then hands it to the Chief as a turn.
    private func answerQuestion(_ messageID: MessageID, in id: ConversationID, partIndex: Int,
                                answer: AgentQuestionAnswer) throws -> HomeOpResult {
        let respondent = AgentQuestionAnswer.Respondent(participant: me.id.rawValue, displayName: me.displayName)
        let atMs = Int64(now().timeIntervalSince1970 * 1000)
        var answered: AgentQuestion?
        try updateMessage(messageID, in: id) { message in
            guard message.parts.indices.contains(partIndex), case .question(let question) = message.parts[partIndex] else {
                throw HomeRejection.invalid("invalid_part_index")
            }
            do {
                let next = try question.answering(answer, respondent: respondent, atMs: atMs)
                message.parts[partIndex] = .question(next)
                answered = next
            } catch AgentQuestionAnswer.Problem.notPending {
                throw HomeRejection.invalid("question_closed")
            } catch {
                throw HomeRejection.invalid("invalid_answer")
            }
        }
        let rev = try conversationState(id).summary.rev
        if let answered {
            let lines = answered.summaryLines(answer).joined(separator: "\n")
            enqueue(ChiefPendingTurn(readSeq: nil, text: "My answer to your question:\n\(lines)", attachmentPaths: [],
                                     replyContext: answered.summary, threadRoot: nil), in: id)
        }
        return HomeOpResult(rev: rev)
    }
}
