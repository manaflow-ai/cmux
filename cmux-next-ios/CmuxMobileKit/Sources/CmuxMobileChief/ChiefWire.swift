import CmuxConversationCore
import Foundation

/// Maps the cmux-tui local conversation owner's JSON (spec/commands.md,
/// `conversation-list`: Summary, Message, Part, Reaction) to the
/// CmuxConversation model, and back for ops.
struct ChiefWire {
    let identity: ChiefIdentity

    // MARK: Dates

    func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let date = try? Date(text, strategy: Self.precise) { return date }
        if let date = try? Date(text, strategy: Self.plain) { return date }
        // Micro- or nanoseconds: keep milliseconds and read it again.
        guard let dot = text.firstIndex(of: "."), let end = text[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) else { return nil }
        let digits = text[text.index(after: dot)..<end]
        guard digits.count > 3 else { return nil }
        return try? Date(String(text[...dot]) + digits.prefix(3) + text[end...], strategy: Self.precise)
    }

    // Made once: two formatters per message cost about 1,500 for a 500-message page.
    private static let precise = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    // MARK: Tapbacks

    /// Wire tapback names are Messages' internal names; the model uses the glyph names.
    static let tapbacks: [(wire: String, reaction: ConversationReaction)] = [
        ("love", .heart), ("like", .thumbsup), ("dislike", .thumbsdown),
        ("laugh", .haha), ("emphasize", .exclamation), ("question", .question),
    ]

    func reaction(kind: Any?) -> ConversationReaction? {
        guard let kind = kind as? [String: Any] else { return nil }
        if let tapback = kind["tapback"] as? String {
            return Self.tapbacks.first { $0.wire == tapback }?.reaction
        }
        if let emoji = kind["emoji"] as? String { return ConversationReaction(rawValue: emoji) }
        return nil
    }

    func wireKind(_ reaction: ConversationReaction) -> [String: Any] {
        if let emoji = reaction.emoji { return ["emoji": emoji] }
        let name = Self.tapbacks.first { $0.reaction == reaction }?.wire ?? "love"
        return ["tapback": name]
    }

    // MARK: Messages

    /// Text of a message: its text parts, and a line for each work card and question.
    func text(parts: [[String: Any]]) -> String {
        parts.compactMap { part -> String? in
            switch part["type"] as? String {
            case "text": return part["text"] as? String
            case "work":
                let status = part["status"] as? String ?? "running"
                return (part["preview"] as? String).map { "\($0) (\(status))" } ?? "Working (\(status))"
            case "question":
                let items = part["items"] as? [[String: Any]] ?? []
                return items.compactMap { $0["prompt"] as? String }.joined(separator: "\n")
            case "link_preview": return part["url"] as? String
            default: return nil
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// An `attachment` part as the model's attachment, rendered from `bytes`
    /// (the owner serves bytes by hash, not by URL).
    func attachment(_ part: [String: Any], bytes: Data?) -> ConversationAttachment? {
        guard part["type"] as? String == "attachment", let hash = part["hash"] as? String else { return nil }
        let mime = part["mime_type"] as? String ?? "application/octet-stream"
        let name = part["name"] as? String ?? "Attachment"
        let byteCount = (part["byte_count"] as? NSNumber)?.int64Value ?? Int64(bytes?.count ?? 0)
        let width = (part["width"] as? NSNumber)?.intValue ?? 0
        let height = (part["height"] as? NSNumber)?.intValue ?? 0
        let isImage = mime.hasPrefix("image/")
        return ConversationAttachment(
            id: "att:\(hash)", kind: isImage ? .image : .file, width: width, height: height, url: nil, localData: bytes,
            file: isImage ? nil : ConversationFileInfo(name: name, mimeType: mime, byteCount: byteCount)
        )
    }

    /// `peerReadSeq`: Chief's read cursor; my messages at or below it read as Read.
    func message(_ object: [String: Any], peerReadSeq: Int, bytes: [String: Data] = [:]) -> ConversationMessage? {
        guard let id = object["id"] as? String, let seq = (object["seq"] as? NSNumber)?.intValue,
              let author = object["author"] as? String else { return nil }
        let parts = object["parts"] as? [[String: Any]] ?? []
        let mine = author == identity.meID
        let reactions = (object["reactions"] as? [[String: Any]] ?? []).compactMap { mark -> ConversationReactionMark? in
            guard let who = mark["author"] as? String, let reaction = reaction(kind: mark["kind"]) else { return nil }
            return ConversationReactionMark(participantID: who, reaction: reaction)
        }
        let retracted = date(object["retracted_at"])
        // A failed turn's note reads as a plain sentence (never the harness's
        // raw error, which names internal hosts); the raw text is kept for
        // diagnostics by the backend (``failure(_:)``).
        var shown = retracted == nil ? text(parts: parts) : ""
        if author == identity.chiefID, let failure = ChiefTurnFailure(text: shown) { shown = failure.displayText }
        // Chief and agents write Markdown links; the bubble shows each label as
        // a link. My own text stays as typed (Edit must get it back verbatim).
        let shownMentions = retracted == nil ? mentions(parts: parts) : []
        let linked: (text: String, links: [ConversationTextLink], mentions: [ConversationMention]) = mine
            ? (shown, [], shownMentions)
            : ConversationMarkdownLinks.extract(shown, mentions: shownMentions)
        return ConversationMessage(
            id: id, seq: seq, clientMessageID: object["client_msg_id"] as? String, senderID: author,
            sentAt: date(object["created_at"]) ?? Date(),
            text: linked.text,
            replyToID: (object["reply_to"] as? [String: Any])?["message_id"] as? String,
            editedAt: date(object["edited_at"]),
            unsentAt: retracted,
            reactions: reactions,
            attachments: retracted == nil ? parts.compactMap { attachment($0, bytes: ($0["hash"] as? String).flatMap { bytes[$0] }) } : [],
            delivery: mine ? (seq <= peerReadSeq ? .read(nil) : .delivered) : nil,
            mentions: linked.mentions,
            links: linked.links
        )
    }

    /// The failed turn a Chief message reports, from its raw text.
    func failure(_ object: [String: Any]) -> ChiefTurnFailure? {
        guard object["author"] as? String == identity.chiefID,
              object["retracted_at"] == nil || object["retracted_at"] is NSNull else { return nil }
        return ChiefTurnFailure(text: text(parts: object["parts"] as? [[String: Any]] ?? []))
    }

    func textParts(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text]]
    }

    /// A text part; each mention is a run naming its participant, as the
    /// Mac's Home sends them (`HomeMentions.runs`, UTF-16 offsets).
    func textPart(_ text: String, mentions: [ConversationMention]) -> [String: Any] {
        var part: [String: Any] = ["type": "text", "text": text]
        let runs = mentions.map { ["start": $0.location, "length": $0.length, "mention": $0.participantID] as [String: Any] }
        if !runs.isEmpty { part["runs"] = runs }
        return part
    }

    /// The mention runs of a message's first text part, as the model's mentions.
    func mentions(parts: [[String: Any]]) -> [ConversationMention] {
        guard let first = parts.first(where: { $0["type"] as? String == "text" }) else { return [] }
        return (first["runs"] as? [[String: Any]] ?? []).compactMap { run in
            guard let who = run["mention"] as? String, let start = (run["start"] as? NSNumber)?.intValue,
                  let length = (run["length"] as? NSNumber)?.intValue else { return nil }
            return ConversationMention(participantID: who, location: start, length: length)
        }
    }

    // MARK: Conversations

    func info(_ summary: [String: Any]) -> ConversationInfo? {
        guard let id = summary["id"] as? String else { return nil }
        let participants = (summary["participants"] as? [[String: Any]] ?? []).compactMap { p -> ConversationParticipant? in
            guard let pid = p["id"] as? String else { return nil }
            let name = p["display_name"] as? String ?? pid
            let isMe = pid == identity.meID
            // Chief is drawn with its avatar text everywhere (the header too).
            let initials = isMe ? "" : pid == identity.chiefID ? identity.avatar
                : String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
            return ConversationParticipant(id: pid, name: isMe ? "You" : name, initials: initials, colorHex: "#636366", isMe: isMe)
        }
        return ConversationInfo(
            id: id, title: summary["title"] as? String ?? identity.title,
            kind: participants.count > 2 ? .group : .direct, participants: participants,
            listState: ConversationListState(pinned: true, pinOrder: 0)
        )
    }

    func isChief(_ summary: [String: Any]) -> Bool {
        let ids = (summary["participants"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return ids.contains(identity.chiefID) && ids.contains(identity.meID)
    }

    /// The conversation the Mac's Home shows as Chief (`HomeChiefName.select`):
    /// the oldest one with Chief in it, by `created_at` then id.
    func chiefConversation(in summaries: [[String: Any]]) -> String? {
        summaries.filter(isChief)
            .min { a, b in
                let (ac, bc) = (a["created_at"] as? String ?? "", b["created_at"] as? String ?? "")
                return ac != bc ? ac < bc : (a["id"] as? String ?? "") < (b["id"] as? String ?? "")
            }?["id"] as? String
    }

    func readCursor(_ summary: [String: Any], of participant: String) -> Int {
        ((summary["read_cursors"] as? [String: Any])?[participant] as? NSNumber)?.intValue ?? 0
    }

    func participants() -> [[String: Any]] {
        [
            ["id": identity.meID, "kind": "human", "display_name": "You"],
            ["id": identity.chiefID, "kind": "agent", "display_name": identity.title, "agent_class": "agent"],
        ]
    }
}
