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
        aliases[item.key] ?? rowSafe(item.key.rawValue)
    }

    /// MessagesLab's row keys are "kind:messageID[:part]" and RowBuilder.owner
    /// splits at colons; the Chief's keys have colons ("turn:s1:2"). A colon
    /// (and the escape character) is percent-encoded, so the id stays unique
    /// and its rows are found by the incremental row update.
    static func rowSafe(_ key: String) -> ID {
        guard key.contains(":") || key.contains("%") else { return key }
        return key.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ":", with: "%3A")
    }

    /// A hash's bubble picture (`HomeMedia.asset`), nil until it is ready.
    typealias Media = (String) -> String?

    /// A link card's fetched preview (`LinkPreviews.cached`), nil: the domain card.
    typealias Links = (String) -> LinkMetadata?

    static func message(_ item: TranscriptItem, aliases: [IdempotencyKey: ID], me: ParticipantID,
                        summary: ConversationSummary?, media: Media = { _ in nil }, links: Links = { _ in nil }) -> Message {
        let (parts, owners) = projectedParts(item, summary: summary, media: media, links: links)
        let messageID = id(item, aliases: aliases)
        // A person's text shows as typed, and so does a part with mentions (their offsets index
        // the text as written): MessagesLab's Markdown engine skips the message (only an
        // agent's text is Markdown, HomeMarkdown). Marked before the message is measured.
        let mentions = item.parts.contains { if case let .text(_, m) = $0 { return !m.isEmpty } else { return false } }
        MarkdownStore.shared.setPlain(messageID, !isAgent(item.author, summary) || mentions)
        return Message(id: messageID, senderId: item.author.rawValue, sentAt: Instant.format(item.createdAt),
                parts: parts, replyTo: nil, status: status(item, me: me, summary: summary), edits: nil,
                retractedAt: item.isRetracted ? Instant.format(item.editedAt ?? item.createdAt) : nil,
                reactions: item.reactions.map { reaction($0, partIndex: projectedIndex($0.partIndex, owners)) })
    }

    /// The item's parts as MessagesLab shows them, and for each one the
    /// HomeStore part it came from. A text part follows Messages' link rule
    /// (the vendored `TextParts.parts`, as MessagesLab's own send does): a
    /// line that is only a URL is a link card in its place, the other lines
    /// stay one text bubble, a URL in a sentence gets no card. So the local
    /// send and the message HomeStore stores show the same bubbles.
    static func projectedParts(_ item: TranscriptItem, summary: ConversationSummary?, media: Media = { _ in nil },
                               links: Links = { _ in nil }) -> (parts: [Part], owners: [Int]) {
        guard !item.isRetracted else { return ([], []) }
        let markdown = isAgent(item.author, summary)
        var parts: [Part] = [], owners: [Int] = []
        for (i, p) in item.parts.enumerated() {
            let shown = self.parts(p, media: media, progress: item.attachmentProgress, markdown: markdown, links: links)
            parts += shown
            owners += Array(repeating: i, count: shown.count)
        }
        return (parts, owners)
    }

    /// A HomeStore part index as the first MessagesLab part it shows as
    /// (a reaction on a split text sits on its first bubble).
    static func projectedIndex(_ homeIndex: Int, _ owners: [Int]) -> Int {
        owners.firstIndex(of: homeIndex) ?? homeIndex
    }

    /// A MessagesLab part index as the HomeStore part it shows (a tapback's partIndex).
    static func homeIndex(_ projected: Int, _ owners: [Int]) -> Int {
        owners.indices.contains(projected) ? owners[projected] : projected
    }

    /// One HomeStore part as MessagesLab parts: a text part by Messages'
    /// link rule (people's text with its URLs as link runs, an agent's as
    /// Markdown per bubble); every other part is one part. Text with
    /// mentions stays one bubble (the mention offsets index the whole text),
    /// and so does an agent's text with a fenced block (a split would cut it).
    static func parts(_ p: MessagePart, media: Media = { _ in nil }, progress: [String: Double] = [:], markdown: Bool = false,
                      links: Links = { _ in nil }) -> [Part] {
        guard case .text(let text, let mentions) = p, mentions.isEmpty,
              !(markdown && (text.contains("```") || text.contains("~~~"))) else {
            return [part(p, media: media, progress: progress, markdown: markdown)]
        }
        return TextParts.parts(for: text).map { shown in
            switch shown {
            case let .text(t, _) where markdown:
                let (rendered, runs) = HomeMarkdown.render(t)
                return .text(rendered, runs: runs)
            case let .link(url, title, site, image, theme):
                // A preview fetched before (this Mac's sends, taps) fills the card, as `.linkMetadata` did;
                // otherwise the domain card (HomeStore's message is settled: no grey loading card).
                guard let meta = links(url) else {
                    let host = URL(string: url).map(TextParts.host) ?? url
                    return .link(url: url, title: title ?? host, siteName: site ?? host, image: image, theme: theme)
                }
                return .link(url: url, title: meta.title ?? title, siteName: meta.site ?? site, image: meta.image ?? image, theme: theme)
            default:
                return shown
            }
        }
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

    /// Agents write Markdown (the Chief's replies); people's text is shown as typed.
    static func isAgent(_ author: ParticipantID, _ summary: ConversationSummary?) -> Bool {
        summary?.participants.first { $0.id == author }?.kind == .agent
    }

    /// `markdown`: an agent's text part shows its Markdown styled (HomeMarkdown).
    /// A part with mentions keeps its text as written (mention offsets index it).
    static func part(_ p: MessagePart, media: Media = { _ in nil }, progress: [String: Double] = [:], markdown: Bool = false) -> Part {
        switch p {
        case .text(let text, let mentions) where markdown && mentions.isEmpty:
            let (shown, runs) = HomeMarkdown.render(text)
            return .text(shown, runs: runs)
        case .text(let text, let mentions):
            return .text(text, runs: mentions.map {
                TextRun(start: $0.start, length: $0.length, style: nil, link: nil, mention: $0.participant.rawValue, detected: nil)
            })
        case .linkPreview(let link):
            let host = URL(string: link.url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            return .link(url: link.url, title: link.title ?? host, siteName: host, image: nil, theme: "dark")
        case .attachment(let ref):
            return .attachment(attachment(ref, picture: media(ref.hash), progress: progress[ref.hash]))
        case .location(let place):
            return .location(latitude: place.latitude, longitude: place.longitude, title: place.label, subtitle: nil)
        case .work, .approval, .question:
            // Agent session, approval and question cards are not MessagesLab rows
            // yet: their text. The question card moves to the custom-row seam.
            return .text(p.plainText, runs: [])
        }
    }

    /// MessagesLab's attachment kind (its row drawing): image and video
    /// bubbles, the audio row, else the file row.
    static func kind(of ref: AttachmentRef) -> String {
        let type = ref.mimeType.lowercased()
        if type.hasPrefix("image/") { return "image" }
        if type.hasPrefix("video/") { return "video" }
        if type.hasPrefix("audio/") { return "audio" }
        return "file"
    }

    /// A HomeStore attachment part as MessagesLab's: the id is the content
    /// hash; an image's picture is its asset, a video's its poster (the row
    /// drawing reads `poster ?? asset`, so a video never loads the movie);
    /// an upload in flight is MessagesLab's `.uploading` transfer.
    static func attachment(_ ref: AttachmentRef, picture: String?, progress: Double?) -> Attachment {
        let kind = kind(of: ref)
        return Attachment(id: ref.hash, kind: kind, fileName: ref.name, mimeType: ref.mimeType, byteSize: ref.byteCount,
                          asset: kind == "image" ? picture : nil, poster: kind == "video" ? picture : nil,
                          width: ref.width, height: ref.height, durationSeconds: ref.durationMs.map { Double($0) / 1000 },
                          transfer: progress.map { .uploading($0) } ?? .done)
    }

    static func reaction(_ r: CmuxHomeCore.Reaction, partIndex: Int? = nil) -> Reaction {
        Reaction(senderId: r.author.rawValue, partIndex: partIndex ?? r.partIndex, kind: kind(r.kind), at: "")
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
