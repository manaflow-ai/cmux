import CmuxHomeCore
import Foundation

/// CmuxHomeCore values as MessagesLab model values (catalyst Model.swift).
/// Pure functions: the adapter (`HomeProjection`) builds the projection
/// store's conversation and actions from them.
///
/// Ids: a message's projection id is its HomeStore key (a pending send and
/// its committed echo share it, TranscriptItem.key), or, for a send this
/// view started, the local id the reducer gave it (`aliases`).
enum HomeMapping {
    static func id(_ item: TranscriptItem, aliases: [IdempotencyKey: ID]) -> ID {
        aliases[item.key] ?? item.key.rawValue
    }

    static func message(_ item: TranscriptItem, aliases: [IdempotencyKey: ID], me: ParticipantID,
                        summary: ConversationSummary?) -> Message {
        Message(id: id(item, aliases: aliases), senderId: item.author.rawValue, sentAt: Instant.format(item.createdAt),
                parts: item.isRetracted ? [] : item.parts.map(part),
                replyTo: nil, status: status(item, me: me, summary: summary), edits: nil,
                retractedAt: item.isRetracted ? Instant.format(item.editedAt ?? item.createdAt) : nil,
                reactions: item.reactions.map(reaction))
    }

    /// My messages: sending, delivered once the owner committed it, read when
    /// another participant's read cursor reached it. Others' messages: nil.
    static func status(_ item: TranscriptItem, me: ParticipantID, summary: ConversationSummary?) -> DeliveryStatus? {
        guard item.author == me else { return nil }
        switch item.delivery {
        case .sending: return .sending
        case .notDelivered:
            // It reached the owner and got no answer: "May Not Have Been Delivered".
            return .failed(reason: item.mayHaveBeenDelivered ? CmuxStrings.mayHaveBeenDeliveredReason : nil)
        case .committed:
            guard let seq = item.seq else { return .sent }
            let readers = (summary?.readCursors ?? [:]).filter { $0.key != me && $0.value >= seq }
            if let reader = readers.keys.sorted(by: { $0.rawValue < $1.rawValue }).first {
                let at = summary?.readCursorTimes[reader] ?? item.createdAt
                return .read(at: Instant.format(at))
            }
            return .delivered(at: Instant.format(item.createdAt))
        }
    }

    static func part(_ p: MessagePart) -> Part {
        switch p {
        case .text(let text, let mentions):
            return .text(text, runs: mentions.map {
                TextRun(start: $0.start, length: $0.length, style: nil, link: nil, mention: $0.participant.rawValue, detected: nil)
            })
        case .linkPreview(let link):
            let host = URL(string: link.url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            return .link(url: link.url, title: link.title ?? host, siteName: host, image: nil, theme: "dark")
        case .attachment(let file):
            // Lane 16 seam: the bytes (blob store) and the image bubble land
            // with the attachment intake; here the row draws the file card.
            let kind = file.mimeType.hasPrefix("image/") ? "image" : file.mimeType.hasPrefix("video/") ? "video" : "file"
            return .attachment(Attachment(id: file.hash, kind: kind, fileName: file.name, mimeType: file.mimeType,
                                          byteSize: file.byteCount, asset: nil, poster: nil, width: file.width,
                                          height: file.height, durationSeconds: nil, transfer: .done))
        case .location(let place):
            return .location(latitude: place.latitude, longitude: place.longitude, title: place.label, subtitle: nil)
        case .work, .approval:
            // Agent session and approval cards are not MessagesLab rows: their text.
            return .text(p.plainText, runs: [])
        }
    }

    static func reaction(_ r: CmuxHomeCore.Reaction) -> Reaction {
        Reaction(senderId: r.author.rawValue, partIndex: r.partIndex, kind: kind(r.kind), at: "")
    }

    static func kind(_ k: CmuxHomeCore.Reaction.Kind) -> Reaction.Kind {
        switch k {
        case .tapback(let t): return .tapback(t.rawValue)
        case .emoji(let e): return .emoji(e)
        }
    }

    static func kind(_ k: Reaction.Kind) -> CmuxHomeCore.Reaction.Kind {
        switch k {
        case .tapback(let t): return CmuxHomeCore.Reaction.Tapback(rawValue: t).map { .tapback($0) } ?? .emoji(t)
        case .emoji(let e): return .emoji(e)
        }
    }

    static func participants(_ summary: ConversationSummary?, me: ParticipantID) -> [Participant] {
        var out = (summary?.participants ?? []).map {
            Participant(id: $0.id.rawValue, displayName: $0.displayName, isMe: $0.id == me, avatar: .monogram($0.initials))
        }
        if !out.contains(where: \.isMe) { out.append(Participant(id: me.rawValue, displayName: "", isMe: true, avatar: nil)) }
        return out
    }

    static func title(_ summary: ConversationSummary?, me: ParticipantID) -> String {
        summary?.displayTitle(me: me) ?? ""
    }

    /// The other participant's initials (the header avatar); a group shows
    /// the title's.
    static func initials(_ summary: ConversationSummary?, me: ParticipantID) -> String {
        let others = (summary?.participants ?? []).filter { $0.id != me }
        if others.count == 1, let other = others.first { return other.initials }
        let words = title(summary, me: me).split(separator: " ").prefix(2).compactMap(\.first)
        return String(words).uppercased()
    }

    /// The loaded window's place in the history: (messages before it, total).
    static func window(_ items: [TranscriptItem], summary: ConversationSummary?) -> (start: Int, total: Int) {
        let first = items.first(where: { $0.seq != nil })?.seq ?? 1
        let start = max(0, Int(first) - 1)
        return (start, max(start + items.count, Int(summary?.lastSeq ?? 0)))
    }
}
