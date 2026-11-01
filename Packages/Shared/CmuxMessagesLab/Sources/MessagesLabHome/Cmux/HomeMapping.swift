import CmuxHomeCore
import CmuxHomeRender
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

    /// A thread root's MessagesLab id and part owners, by its owner message id; nil when the
    /// root is not among the mapped items or is retracted (a reply then shows as a plain message).
    typealias Roots = (MessageID) -> (id: ID, owners: [Int])?

    /// The thread roots among `items`, for `message(_:roots:)`: indexed by message id, a root's
    /// parts mapped only when a reply asks for it.
    static func roots(in items: [TranscriptItem], aliases: [IdempotencyKey: ID], summary: ConversationSummary?,
                      media: @escaping Media = { _ in nil }, links: @escaping Links = { _ in nil }) -> Roots {
        let wanted = indexed(items)
        guard !wanted.isEmpty else { return { _ in nil } }
        var byID: [MessageID: TranscriptItem] = [:]
        for item in items {
            if let mid = item.messageID, wanted.contains(mid), !item.isRetracted { byID.updateValue(item, forKey: mid) }
        }
        let found = byID
        // A root with many replies is asked once per reply, per diff: map its parts once.
        let mapped = RootCache()
        return { root in
            if let hit = mapped.entries[root] { return hit }
            let entry = found.value(for: root).map { (id($0, aliases: aliases), projectedParts($0, summary: summary, media: media, links: links).owners) }
            mapped.entries.updateValue(entry, forKey: root) // a miss (nil) is cached too
            return entry
        }
    }

    /// The roots one `roots(in:)` answer already mapped (nil: not among the items).
    private final class RootCache {
        var entries: [MessageID: (id: ID, owners: [Int])?] = [:]
    }

    /// A thread reply's root as MessagesLab's `replyTo` (HomeStore `threadRoot`; the part from
    /// `replyTo` when it names a later part of the root, else the root's last part): MessagesLab
    /// lays it out and animates its arrival as a thread reply (connector, the root's 32 pt thread
    /// gap). nil for a message that is no thread reply, or whose root is not among the mapped items
    /// or retracted.
    static func replyTo(_ item: TranscriptItem, roots: Roots) -> PartRef? {
        guard let root = item.threadRoot, root != item.messageID, let r = roots(root), !r.owners.isEmpty else { return nil }
        let homePart = item.replyTo?.message == root ? (item.replyTo?.partIndex ?? 0) : 0
        // HomeStore names a whole message as part 0 (`PartRef(message:)`): that reply answers the root's
        // last bubble, so the connector runs only from the bubble right above it, as in Messages. From
        // part 0 it ran past a pasted block and pictures above the root's text (refs/imessage-layout/1.png).
        // A part index that no shown part owns is the last part too.
        let last = r.owners.count - 1
        return PartRef(messageId: r.id, partIndex: homePart == 0 ? last : r.owners.firstIndex(of: homePart) ?? last)
    }

    /// The client id prefix of Chief's first-launch welcome messages (CmuxNext `ChiefWelcome`).
    static let welcomeKeyPrefix = "chief-welcome-"

    static func message(_ item: TranscriptItem, aliases: [IdempotencyKey: ID], me: ParticipantID,
                        summary: ConversationSummary?, media: Media = { _ in nil }, links: Links = { _ in nil },
                        roots: Roots = { _ in nil }) -> Message {
        let (parts, owners) = projectedParts(item, summary: summary, media: media, links: links)
        let messageID = id(item, aliases: aliases)
        // A person's text shows as typed, and so does a part with mentions (their offsets index
        // the text as written): only an agent's text is Markdown (MessagesLab's opt-in
        // `Message.format`; plain by default, so a local send is plain before HomeStore has it).
        let mentions = item.parts.contains { if case let .text(_, m) = $0 { return !m.isEmpty } else { return false } }
        let format: MessageFormat = isAgent(item.author, summary) && !mentions ? .markdown : .plain
        var message = Message(id: messageID, senderId: item.author.rawValue, sentAt: Instant.format(item.createdAt),
                parts: parts, replyTo: replyTo(item, roots: roots), status: status(item, me: me, summary: summary), edits: edits(item),
                retractedAt: item.isRetracted ? Instant.format(item.editedAt ?? item.createdAt) : nil,
                reactions: item.reactions.map { reaction($0, partIndex: projectedIndex($0.partIndex, owners)) }, format: format)
        // ThreadMode.tree: the message a nested reply answers (HomeMapping+Tree.swift).
        message.parent = parent(item, roots: roots)
        // Chief's first-launch welcome (CmuxNext ChiefWelcome, client ids "chief-welcome-…"): each bubble its own group.
        if item.key.rawValue.hasPrefix(welcomeKeyPrefix) { message.cmuxStandsAlone = true }
        if !item.isRetracted, !item.parts.isEmpty, parts.isEmpty {
            // Nothing to read (a Chief turn's done marker, a work part with no preview): kept so
            // its seq still moves the read cursor, drawn as no row and counted as no reply.
            message.deletedAt = Instant.format(item.createdAt)
            message.replyTo = nil
            message.parent = nil
        }
        return message
    }

    /// An edited message's edit as MessagesLab's `Message.edits`, so it shows "Edited" under it when it loads
    /// already edited (a snapshot, a rebuild, an older page), as MessagesLab does: before, only a live edit
    /// (HomeDiff `.edit`) added the label, and the next rebuild lost it. MessagesLab's `Edit.text` is the text
    /// before the edit; HomeStore keeps no earlier text, so the edit holds the current text (the transcript reads
    /// only that an edit exists; ComposerHistory reads the parts).
    static func edits(_ item: TranscriptItem) -> [Message.Edit]? {
        guard let at = item.editedAt, !item.isRetracted else { return nil }
        let text = item.parts.compactMap { if case .text(let t, _) = $0 { t } else { nil } }.joined(separator: "\n")
        return [Message.Edit(text: text, at: Instant.format(at))]
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
        if let row = item.agentMessage {
            // A fold or notes row: a muted caption line, no bubble (HomeAgentFoldRowProvider).
            if let caption = HomeAgentFoldRowProvider.part(row) { return ([caption], [0]) }
            // An agent-message row: its words, as Markdown (the fold's link, the bold "Chief → a917" line).
            let shown = self.parts(.text(agentMessageText(row)), media: media, markdown: true, links: links)
            return (shown, Array(repeating: 0, count: shown.count))
        }
        let markdown = isAgent(item.author, summary)
        var parts: [Part] = [], owners: [Int] = []
        for (i, p) in item.parts.enumerated() {
            let shown = self.parts(p, media: media, progress: item.attachmentProgress, markdown: markdown, links: links)
            parts += shown
            owners += Array(repeating: i, count: shown.count)
        }
        return (parts, owners)
    }

    /// What an agent-message row says, as Markdown. A fold or notes row is one muted (italic) line with
    /// no link, a click anywhere on the row opens or closes it ("▸ Agent messages (6) · a938, a917";
    /// "▸ Disconnected (5) · `a1` `a2`", the agents as code chips). A message is its bold
    /// "from → to" line over the whole message; a status note is the agent's chip and its words, muted.
    static func agentMessageText(_ row: HomeAgentMessageRow) -> String {
        switch row.kind {
        case let .fold(count, peers, expanded):
            let label = expanded ? CmuxStrings.hideAgentMessages(count) : CmuxStrings.showAgentMessages(count)
            return expanded ? "*▾ \(label)*" : "*▸ \(label)* · \(HomeAgentMessageRow.peerPreview(peers.map(markdownEscaped), separator: ", "))"
        case let .notes(count, peers, reason, expanded):
            let label = CmuxStrings.agentNotes(reason, count)
            return expanded ? "*▾ \(label)*" : "*▸ \(label)* · \(HomeAgentMessageRow.peerPreview(peers.map(codeChip), separator: " "))"
        case let .note(peer, _, text):
            return "\(codeChip(peer)) *\(markdownEscaped(text))*"
        case let .message(from, to, _, text):
            return "**\(markdownEscaped(from)) → \(markdownEscaped(to))**\n\(text)"
        }
    }

    /// `name` as an inline code span (a chip-like pill), its backticks dropped.
    private static func codeChip(_ name: String) -> String { "`\(name.replacingOccurrences(of: "`", with: ""))`" }

    /// `name` with the Markdown punctuation that would change its look escaped (an agent id, a display name).
    private static func markdownEscaped(_ name: String) -> String {
        var out = ""
        for ch in name {
            if "\\`*_[]<>#|~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// A HomeStore part index as the first MessagesLab part it shows as
    /// (a reaction on a split text sits on its first bubble).
    static func projectedIndex(_ homeIndex: Int, _ owners: [Int]) -> Int {
        owners.firstIndex(of: homeIndex) ?? homeIndex
    }

    /// A MessagesLab part index as the HomeStore part it shows (a tapback's partIndex).
    static func homeIndex(_ projected: Int, _ owners: [Int]) -> Int {
        owners[checked: projected] ?? projected // // crash program: checked (a projected index past the owners keeps its value)
    }

    /// One HomeStore part as MessagesLab parts: a text part by Messages'
    /// link rule (people's text with its URLs as link runs, an agent's as
    /// Markdown per bubble); every other part is one part. Text with
    /// mentions stays one bubble (the mention offsets index the whole text),
    /// and so does an agent's text with a fenced block (a split would cut it).
    ///
    /// A closed ```` ```mermaid ```` fence whose source the installed diagram renderer draws
    /// (`HomeDiagramRowProvider`) is a diagram bubble of its own, between the text before and
    /// after it; without a renderer, or for a source it refuses, the fence stays in the text.
    static func parts(_ p: MessagePart, media: Media = { _ in nil }, progress: [String: Double] = [:], markdown: Bool = false,
                      links: Links = { _ in nil }) -> [Part] {
        // A work part shows its preview; its session id is no text (`WorkRef.shownText`).
        if case .work(let work) = p, work.shownText == nil { return [] }
        // An agent's pipe tables are cards of their own (HomeTableRowProvider), between its text.
        func text(_ piece: String) -> [Part] {
            if markdown, let split = tableParts(piece, { textParts(.text($0), media: media, progress: progress, markdown: markdown, links: links) }) {
                return split
            }
            return textParts(.text(piece), media: media, progress: progress, markdown: markdown, links: links)
        }
        if case .text(let whole, let mentions) = p, mentions.isEmpty, let diagrams = HomeDiagramRowProvider.installed,
           let split = diagramParts(whole, diagrams: diagrams, text) {
            return split
        }
        if case .text(let whole, let mentions) = p, mentions.isEmpty, markdown {
            return text(whole)
        }
        return textParts(p, media: media, progress: progress, markdown: markdown, links: links)
    }

    /// `text` cut at its pipe tables: the text pieces by `textParts`, each table a table or plan card.
    /// nil when it has no table, or tables are off (Debug Settings > Home > Rich tables), or no provider
    /// is installed: the text then maps as it always did, tables as written in the bubble.
    static func tableParts(_ text: String, _ textParts: (String) -> [Part]) -> [Part]? {
        guard HomeTableRowProvider.isOn, HomeTableRowProvider.installed != nil else { return nil }
        let segments = HomeTableSplitter().segments(in: text)
        guard segments.contains(where: { if case .table = $0 { return true } else { return false } }) else { return nil }
        var out: [Part] = []
        var pending = ""
        func flush() {
            let piece = pending.trimmingCharacters(in: .newlines)
            pending = ""
            if !piece.trimmingCharacters(in: .whitespaces).isEmpty { out += textParts(piece) }
        }
        for segment in segments {
            switch segment {
            case .text(let piece):
                pending += pending.isEmpty ? piece : "\n" + piece
            case .table(let table, let raw):
                if let card = HomeTableRowProvider.part(table, raw: raw) {
                    flush()
                    out.append(card)
                } else {
                    pending += pending.isEmpty ? raw : "\n" + raw
                }
            }
        }
        flush()
        return out
    }

    /// `text` cut at its Mermaid fences: the text pieces by `textParts`, each fence the renderer
    /// draws as a diagram bubble, a refused fence kept in the text around it. nil when no fence
    /// becomes a diagram (the text then maps as it always did).
    static func diagramParts(_ text: String, diagrams: HomeDiagramRowProvider, _ textParts: (String) -> [Part]) -> [Part]? {
        let segments = HomeMermaidSplitter().segments(in: text)
        guard segments.contains(where: { if case .mermaid = $0 { return true } else { return false } }) else { return nil }
        var out: [Part] = []
        var pending = ""
        var drew = false
        func flush() {
            let piece = pending.trimmingCharacters(in: .newlines)
            pending = ""
            if !piece.trimmingCharacters(in: .whitespaces).isEmpty { out += textParts(piece) }
        }
        for segment in segments {
            switch segment {
            case .text(let piece):
                pending += piece
            case .mermaid(let source, let fenced):
                if let diagram = diagrams.part(source) {
                    flush()
                    out.append(diagram)
                    drew = true
                } else {
                    pending += fenced
                }
            }
        }
        flush()
        return drew ? out : nil
    }

    /// One HomeStore part as MessagesLab parts, without diagrams (`parts`).
    private static func textParts(_ p: MessagePart, media: Media, progress: [String: Double], markdown: Bool, links: Links) -> [Part] {
        guard case .text(let text, let mentions) = p, mentions.isEmpty,
              !(markdown && (text.contains("```") || text.contains("~~~"))) else {
            return [part(p, media: media, progress: progress, markdown: markdown, links: links)]
        }
        // A person's reply that starts with a quote (Reply to Selection, ReplyQuote): the quote shows
        // quietly at the top of the first text bubble, the reply below it.
        if !markdown, let (quote, body) = ReplyQuote.split(text) {
            let (head, run) = ReplyQuote.head(quote)
            var shown = body.isEmpty ? [] : TextParts.parts(for: body)
            if case let .text(t, runs)? = shown.first, !t.isEmpty {
                let shift = (head as NSString).length + 1
                shown[0] = .text(head + "\n" + t, runs: [run] + runs.map { var r = $0; r.start += shift; return r })
            } else {
                shown.insert(.text(head, runs: [run]), at: 0)
            }
            return shown
        }
        return TextParts.parts(for: text).map { shown in
            switch shown {
            case let .text(t, _) where markdown:
                let (rendered, runs) = HomeMarkdown.render(t, chips: HomeLinkChip.showsInTranscript)
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
    static func part(_ p: MessagePart, media: Media = { _ in nil }, progress: [String: Double] = [:], markdown: Bool = false,
                     links: Links = { _ in nil }) -> Part {
        switch p {
        case .text(let text, let mentions) where markdown && mentions.isEmpty:
            let (shown, runs) = HomeMarkdown.render(text, chips: HomeLinkChip.showsInTranscript)
            return .text(shown, runs: runs)
        case .text(let text, let mentions):
            return .text(text, runs: mentions.map {
                TextRun(start: $0.start, length: $0.length, style: nil, link: nil, mention: $0.participant.rawValue, detected: nil)
            })
        case .linkPreview(let link):
            // What the sender attached; its picture is a blob fetched by hash (HomeMedia), never
            // the URL. A preview this Mac fetched itself (its send, a tap) fills what the part lacks.
            let host = URL(string: link.url).map(TextParts.host) ?? link.url
            let fetched = links(link.url)
            return .link(url: link.url, title: link.title ?? fetched?.title ?? host, siteName: link.site ?? fetched?.site ?? host,
                         image: link.image.flatMap { media($0.hash) } ?? fetched?.image, theme: "dark")
        case .attachment(let ref):
            return .attachment(attachment(ref, picture: media(ref.hash), progress: progress.value(for: ref.hash))) // // crash program: dictionary read
        case .location(let place):
            return .location(latitude: place.latitude, longitude: place.longitude, title: place.label, subtitle: nil)
        case .work, .approval, .question:
            // Agent session, approval and question cards are not MessagesLab rows
            // yet: their text. The question card moves to the custom-row seam.
            return .text(p.plainText, runs: [])
        }
    }

    /// A link preview's picture as an image attachment ref (HomeMedia loads
    /// it by hash, from the owner's record of the sender's upload).
    static func attachmentRef(_ image: AttachmentDerivedImage) -> AttachmentRef {
        AttachmentRef(hash: image.hash, name: "link-preview", mimeType: image.mimeType, byteCount: image.byteCount)
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

    /// `avatars`: a chosen avatar by participant id (the host's Chief avatars); anyone else draws their initials.
    static func participants(_ summary: ConversationSummary?, me: ParticipantID,
                             avatars: [String: Participant.Avatar] = [:]) -> [Participant] {
        var out = (summary?.participants ?? []).map {
            // The name a person reads (never an internal id): a group transcript shows it over their bubbles.
            Participant(id: $0.id.rawValue, displayName: $0.visibleName, isMe: $0.id == me,
                        avatar: avatars[$0.id.rawValue] ?? .monogram($0.initials))
        }
        if !out.contains(where: \.isMe) { out.append(Participant(id: me.rawValue, displayName: "", isMe: true, avatar: nil)) }
        return out
    }

    static func title(_ summary: ConversationSummary?, me: ParticipantID) -> String {
        summary?.displayTitle(me: me) ?? ""
    }

    /// The loaded window's place in the history: (messages before it, total).
    /// HomeStore's window always ends at the newest message it has (Home has
    /// no pager), so the total is the window's end, never the summary's
    /// lastSeq: that can run ahead of the window (the inbox moves first, or
    /// the view is made before its first page), and MessagesLab appends a
    /// received message only while the window reaches the total (`atNewest`),
    /// so every later message stayed hidden (cx-7nf0).
    static func window(_ items: [TranscriptItem]) -> (start: Int, total: Int) {
        let first = items.first(where: { $0.seq != nil })?.seq ?? 1
        let start = max(0, Int(clamping: first) - 1) // // crash program: a seq past Int.max clamps
        return (start, start + items.count)
    }
}
