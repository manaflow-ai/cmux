import CmuxAgentBrands
import CmuxHomeCore
import Foundation

/// Who an agent's message is from when the agent sent it through its owner's CLI or MCP tool
/// (`cmux chat send`, `cmux chief send`, MCP `chat_send`; cmux-conversation `agent_sender.rs`).
/// Such a message has the owner as its author, a `client_msg_id` that starts with `agent~`, and
/// text that starts with the label `[from APP › PERSONA] ` (u20190, Nov 3: "the user can see who
/// sent what, e.g. Muse sent…, Grok bot sent…"). The transcript shows it as the agent's own
/// message: the label is taken off, and the agent's name and avatar head its run, as a group
/// chat shows another person's run.
///
/// The mark counts only on the owner's own messages: a label another person types names nobody
/// (the same rule as cmux-chief `agent_sender_as`).
struct HomeAgentSender: Hashable {
    /// The `client_msg_id` prefix of a marked message.
    static let mark = "agent~"
    /// The prefix of the participant ids this type makes (never a real participant id).
    static let idPrefix = "agent-sender:"
    /// The separator between the app and the persona (agent_sender.rs `PERSONA_SEPARATOR`).
    static let separator = " › "

    /// The app or bot ("Grok bot", "Claude Code").
    let app: String
    /// The agent or persona inside the app ("Ada"), when the sender named one.
    let persona: String?

    /// The name the transcript shows: `APP › PERSONA`, or the app.
    var label: String { persona.map { app + Self.separator + $0 } ?? app }

    /// The participant this sender is in the projection: one per shown label.
    var participantID: ID { Self.idPrefix + label.lowercased() }

    /// The sender of `item`, when it is a marked message of `me` with a label; else nil.
    init?(_ item: TranscriptItem, me: ParticipantID) {
        guard item.author == me, item.key.rawValue.hasPrefix(Self.mark),
              let label = Self.label(of: item) else { return nil }
        self.init(label: label)
    }

    /// The sender a label names (`Grok bot › Ada`, `Muse`); nil when it names nobody.
    init?(label: String) {
        let pieces = label.components(separatedBy: "›").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let app = pieces.first, !app.isEmpty else { return nil }
        let persona = pieces.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        self.app = app
        self.persona = persona.isEmpty ? nil : persona
    }

    /// The label of `item`'s first text part, without its brackets.
    private static func label(of item: TranscriptItem) -> String? {
        guard let text = firstText(item), text.hasPrefix("[from ") else { return nil }
        let rest = text.dropFirst(6)
        guard let end = rest.range(of: "] ") else { return nil }
        let label = rest.prefix(upTo: end.lowerBound) // no range subscripts
        return label.isEmpty || label.contains("\n") ? nil : String(label)
    }

    private static func firstText(_ item: TranscriptItem) -> String? {
        for part in item.parts { if case let .text(text, _) = part { return text } }
        return nil
    }

    /// `item` with the label taken off its first text part. A part with mentions keeps its text
    /// (their offsets index the text as written).
    func unlabelled(_ item: TranscriptItem) -> TranscriptItem {
        let prefix = "[from \(label)] "
        var item = item
        var done = false
        item.parts = item.parts.map { part in
            guard !done, case let .text(text, mentions) = part else { return part }
            done = true
            guard mentions.isEmpty, text.hasPrefix(prefix) else { return part }
            return .text(String(text.dropFirst(prefix.count)), mentions: [])
        }
        return item
    }

    /// The avatar beside this sender's run: its brand mark (Claude Code, Codex, Grok, …), the
    /// Chief's default for a Chief, else the monogram of its app.
    var avatar: Participant.Avatar {
        if let brand = AgentBrandCatalog.brand(for: app), AgentBrandCatalog.spec(for: brand) != nil {
            return .brand(brand.rawValue)
        }
        let words = app.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        if words.contains(where: { $0.lowercased() == "chief" }) { return .monogram("CH") }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return .monogram(letters.isEmpty ? "?" : letters)
    }

    /// The participant this sender is in the projection.
    var participant: Participant {
        Participant(id: participantID, displayName: label, isMe: false, avatar: avatar)
    }

    /// The senders of `items`' marked messages, in order of their first message, each once.
    static func all(in items: [TranscriptItem], me: ParticipantID) -> [HomeAgentSender] {
        var seen: Set<ID> = []
        var out: [HomeAgentSender] = []
        for item in items {
            guard let sender = HomeAgentSender(item, me: me), seen.insert(sender.participantID).inserted else { continue }
            out.append(sender)
        }
        return out
    }
}
