public import CmuxHomeCore
import Foundation

// External posts: reports from agents outside Home (the `cmux chief send
// --from` path), and a plain-text transcript for readers outside Home.
extension ChiefConversationOwner {
    /// The participant id an external agent named `name` posts as.
    ///
    /// The id is stable for a name (case and punctuation folded), so every
    /// report from the same agent shows under one participant.
    ///
    /// - Parameter name: The agent's display name.
    /// - Returns: `agent_ext_<slug>` (a hash of the name when it has no ASCII
    ///   letters or digits), or nil for a blank name.
    public static func externalParticipantID(for name: String) -> ParticipantID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var slug = ""
        var pendingDash = false
        for scalar in trimmed.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
            if slug.count >= 48 { break }
        }
        if slug.isEmpty {
            // FNV-1a: stable across launches, unlike `hashValue`.
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in trimmed.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            slug = "h" + String(hash, radix: 16)
        }
        return ParticipantID("agent_ext_\(slug)")
    }

    /// Posts a report from an agent outside Home into a conversation.
    ///
    /// The author is an agent participant (`kind` `.agent`, `agentClass`
    /// `.agent`) named `name`; it joins the conversation's participants the
    /// first time it posts. The message commits and publishes like any other.
    /// With `startTurn`, the conversation's Chief then gets a turn whose user
    /// text is `[report from <name>] <text>` (queued behind a running turn).
    ///
    /// - Parameters:
    ///   - conversation: The conversation; nil means the default Chief conversation.
    ///   - name: The reporting agent's display name (1 to 60 characters).
    ///   - text: The report (not empty, at most 64 KiB).
    ///   - startTurn: Whether the Chief answers the report.
    /// - Returns: The committed message's id.
    /// - Throws: ``HomeRejection/invalid(_:)`` (`invalid_name`, `invalid_parts`,
    ///   `unknown_conversation`).
    @discardableResult
    public func postExternal(conversation: ConversationID?, from name: String, text: String,
                             startTurn: Bool) async throws -> MessageID {
        let id = conversation ?? Self.defaultConversationID
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.count <= 60,
              let authorID = Self.externalParticipantID(for: displayName) else {
            throw HomeRejection.invalid("invalid_name")
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.utf8.count <= 65_536 else { throw HomeRejection.invalid("invalid_parts") }
        let state = try conversationState(id)
        if let existing = state.summary.participants.first(where: { $0.id == authorID }) {
            if existing.displayName != displayName {
                try updateConversation(id) { summary in
                    guard let index = summary.participants.firstIndex(where: { $0.id == authorID }) else { return }
                    summary.participants[index].displayName = displayName
                }
            }
        } else {
            let agent = Participant(id: authorID, kind: .agent, displayName: displayName, agentClass: .agent,
                                    ownerUser: me.id)
            try updateConversation(id) { $0.participants.append(agent) }
        }
        let message = try commitMessage(in: id, author: authorID, parts: [.text(body)], key: .make())
        if startTurn {
            enqueue(ChiefPendingTurn(readSeq: message.seq, text: "[report from \(displayName)] \(body)", attachmentPaths: [],
                                     replyContext: nil, threadRoot: nil), in: id)
        }
        return message.id
    }

    /// The newest `limit` messages of a conversation as plain text, one
    /// `<author>: <text>` block per message, oldest first. Retracted
    /// messages are skipped.
    ///
    /// - Parameters:
    ///   - conversation: The conversation; nil means the default Chief conversation.
    ///   - limit: How many recent messages to include (at least 1).
    /// - Throws: ``HomeRejection/invalid(_:)`` for an unknown conversation.
    public func transcriptText(conversation: ConversationID?, limit: Int) throws -> String {
        let page = try snapshot(of: conversation ?? Self.defaultConversationID, tail: max(limit, 1))
        let names = Dictionary(page.conversation.participants.map { ($0.id, $0.displayName) },
                               uniquingKeysWith: { first, _ in first })
        return page.messages
            .filter { !$0.isRetracted }
            .map { "\(names[$0.author] ?? $0.author.rawValue): \($0.plainText)" }
            .joined(separator: "\n")
    }
}
