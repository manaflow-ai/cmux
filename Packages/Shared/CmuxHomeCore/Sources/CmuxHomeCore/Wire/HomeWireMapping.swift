import CmuxAgentQuestion
import Foundation

/// The hosted owners' JSON (home-core records: message rows, conversation
/// heads, inbox entries, thread stats) as Home core types, and Home parts
/// back as owner parts. Pure. Ids, seqs and revisions pass through
/// unchanged: the store's `me` is the server's user id.
struct HomeWireMapping: Sendable {
    private let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private let whole = Date.ISO8601FormatStyle()

    func date(_ value: HomeWireJSON) -> Date? {
        if let text = value.string { return (try? fractional.parse(text)) ?? (try? whole.parse(text)) }
        // Some rows carry Unix milliseconds.
        if let ms = value.double { return Date(timeIntervalSince1970: ms / 1000) }
        return nil
    }

    func string(_ date: Date) -> String { fractional.format(date) }

    // MARK: Records in

    func participant(_ json: HomeWireJSON) -> Participant? {
        guard let id = json["id"].string, !id.isEmpty else { return nil }
        let kind = json["kind"].string
        let isAgent = kind == "agent" || (kind == nil && id.hasPrefix("agent_"))
        let isAddress = kind == "address"
        let name = json["display_name"].string ?? ""
        return Participant(id: ParticipantID(id), kind: isAgent ? .agent : .human, displayName: name,
                           agentClass: isAgent ? (json["agent_class"].string == "mux" ? .chief : .agent) : nil,
                           ownerUser: json["owner_user"].string.map { ParticipantID($0) },
                           membership: isAddress ? .invited : .active,
                           invitedContact: isAddress ? name : nil,
                           role: json["role"].string.flatMap(Participant.Role.init(rawValue:)))
    }

    func part(_ json: HomeWireJSON, messageID: String, index: Int) -> MessagePart {
        switch json["type"].string {
        case "text":
            let mentions = (json["runs"].array ?? []).compactMap { run -> Mention? in
                guard let who = run["mention"].string, let start = run["start"].int, let length = run["length"].int else { return nil }
                return Mention(start: start, length: length, participant: ParticipantID(who))
            }
            return .text(json["text"].string ?? "", mentions: mentions)
        case "work":
            let session = json["session"].string ?? ""
            return .work(WorkRef(session: session, host: json["host"].string, title: session,
                                 status: json["status"].string.flatMap(WorkRef.Status.init(rawValue:)) ?? .running,
                                 preview: json["preview"].string))
        case "attachment":
            if let ref = try? JSONDecoder().decode(AttachmentRef.self, from: json.data) { return .attachment(ref) }
            return .text(json["name"].string ?? "attachment")
        case "link_preview":
            if let link = try? JSONDecoder().decode(LinkPreview.self, from: json.data) { return .linkPreview(link) }
            return .text(json["url"].string ?? "")
        case "question":
            if let payload = try? AgentQuestionJSON(data: json.data),
               let question = AgentQuestion(conversationPart: payload, messageID: messageID, partIndex: index) {
                return .question(question)
            }
            return .text("question")
        default:
            // A part type this build does not know: its link when it has one, else its type.
            if let url = json["url"].string, !url.isEmpty { return .text(url) }
            return .text(json["type"].string ?? "")
        }
    }

    func reaction(_ json: HomeWireJSON) -> Reaction? {
        guard let author = json["author"].string else { return nil }
        let kind: Reaction.Kind
        if let tapback = json["kind"]["tapback"].string {
            kind = Reaction.Tapback(rawValue: tapback).map(Reaction.Kind.tapback) ?? .emoji(tapback)
        } else if let emoji = json["kind"]["emoji"].string {
            kind = .emoji(emoji)
        } else {
            return nil
        }
        return Reaction(author: ParticipantID(author), partIndex: json["part_index"].int ?? 0, kind: kind)
    }

    func message(_ json: HomeWireJSON) -> Message? {
        guard let id = json["id"].string, let conversation = json["conversation"].string, let seq = json["seq"].uint,
              let author = json["author"].string else { return nil }
        let parts = (json["parts"].array ?? []).enumerated().map { part($1, messageID: id, index: $0) }
        let replyTo = json["reply_to"]["message_id"].string.map {
            PartRef(message: MessageID($0), partIndex: json["reply_to"]["part_index"].int ?? 0)
        }
        var message = Message(id: MessageID(id), conversation: ConversationID(conversation), seq: seq,
                              clientMessageID: IdempotencyKey(json["client_msg_id"].string ?? id),
                              author: ParticipantID(author), parts: parts,
                              createdAt: date(json["created_at"]) ?? .distantPast,
                              editedAt: date(json["edited_at"]), retractedAt: date(json["retracted_at"]),
                              reactions: (json["reactions"].array ?? []).compactMap(reaction),
                              replyTo: replyTo,
                              // A message from before threads marked its thread as a reply to the root.
                              threadRoot: (json["thread_root"].string ?? replyTo?.message.rawValue).map { MessageID($0) })
        let thread = json["thread"]
        if thread.object != nil {
            message.thread = ThreadInfo(title: thread["title"].string, owner: thread["owner"].string.map { ParticipantID($0) },
                                        resolvedAtSeq: thread["resolved"]["seq"].uint,
                                        resolvedBy: thread["resolved"]["by"].string.map { ParticipantID($0) })
        }
        return message
    }

    func kind(_ wire: String?) -> ConversationSummary.Kind? {
        switch wire {
        case "group": .group
        case "dm": .direct
        case "chief": .chief
        default: nil
        }
    }

    /// A conversation head (the owner's `state`, or a summary). Participants
    /// who left are not members any more. `lastMessage` names the newest row
    /// the caller has (a snapshot's last row), else the head's own.
    func summary(_ head: HomeWireJSON, lastMessage: Message? = nil) -> ConversationSummary? {
        guard let id = head["id"].string else { return nil }
        let participants = (head["participants"].array ?? []).filter { $0["left_at"].isNull }.compactMap(participant)
        var cursors: [ParticipantID: Seq] = [:]
        for (who, seq) in head["read_cursors"].object ?? [:] {
            if let seq = seq.uint { cursors[ParticipantID(who), default: 0] = max(cursors[ParticipantID(who)] ?? 0, seq) }
        }
        let created = date(head["created_at"]) ?? .distantPast
        return ConversationSummary(
            id: ConversationID(id), owner: .cloud, title: head["title"].string ?? "", participants: participants,
            lastSeq: head["last_seq"].uint ?? lastMessage?.seq ?? 0, rev: head["rev"].uint ?? 0,
            createdAt: created, updatedAt: date(head["updated_at"]) ?? created,
            lastMessage: lastMessage ?? message(head["last_message"]),
            readCursors: cursors, declaredKind: kind(head["kind"].string),
            memberCount: head["member_count"].int,
            chiefReplies: head["settings"]["wake_policy"].string.flatMap(ChiefReplyPolicy.init(rawValue:)))
    }

    /// A conversation known only from its inbox entry (no head read yet): no
    /// participant names, so a DM shows no peer name until its head arrives.
    func summary(entry: HomeWireJSON, me: Participant) -> ConversationSummary? {
        guard let id = entry["conversation"].string else { return nil }
        var participants = [me]
        if let peer = entry["dm_peer"].string, peer != me.id.rawValue {
            let isAgent = peer.hasPrefix("agent_")
            participants.append(Participant(id: ParticipantID(peer), kind: isAgent ? .agent : .human, displayName: "",
                                            agentClass: isAgent ? .agent : nil))
        }
        let at = date(entry["last_at"]) ?? .distantPast
        let lastSeq = entry["last_seq"].uint ?? 0
        // The entry's unread count leaves out the user's own messages: the cursor it implies is a floor.
        let cursor = lastSeq - min(lastSeq, entry["unread"].uint ?? 0)
        var summary = ConversationSummary(id: ConversationID(id), owner: .cloud, title: entry["title"].string ?? "",
                                          participants: participants, lastSeq: lastSeq, rev: entry["rev"].uint ?? 0,
                                          createdAt: at, updatedAt: at, readCursors: [me.id: cursor])
        apply(entry: entry, to: &summary)
        return summary
    }

    /// The user-owned inbox fields (pin, mute, mentions, unread mark) over a
    /// head; a newer entry also moves `lastSeq`.
    func apply(entry: HomeWireJSON, to summary: inout ConversationSummary) {
        summary.pinRank = entry["pinned"].bool == true ? (entry["pin_position"].int ?? 0) : nil
        summary.muted = entry["muted"].bool ?? false
        summary.mentionCount = entry["mentions"].int ?? 0
        // A teammate's entry for someone else's shared Chief conversation says group; the head's chief stays.
        if let kind = kind(entry["kind"].string), summary.declaredKind != .chief { summary.declaredKind = kind }
        if let lastSeq = entry["last_seq"].uint, lastSeq > summary.lastSeq {
            summary.lastSeq = lastSeq
            if let at = date(entry["last_at"]) { summary.updatedAt = max(summary.updatedAt, at) }
        }
    }

    /// Whether an inbox entry belongs in the visible inbox.
    func isListed(_ entry: HomeWireJSON) -> Bool {
        entry["removed"].bool != true && entry["archived"].bool != true
    }

    func threadSummary(_ json: HomeWireJSON) -> ThreadSummary? {
        guard let root = json["root"].string else { return nil }
        return ThreadSummary(root: MessageID(root), replyCount: json["reply_count"].int ?? 0,
                             lastReplySeq: json["last_reply_seq"].uint, lastReplyAt: date(json["last_reply_at"]),
                             authors: (json["authors"].array ?? []).compactMap(\.string).map { ParticipantID($0) })
    }

    /// The message rows of a snapshot frame or value (`rows: {table: "msg",
    /// rows: [{key, n, row}]}`), ascending by seq.
    func snapshotMessages(_ snapshot: HomeWireJSON) -> [Message] {
        guard snapshot["rows"]["table"].string ?? "msg" == "msg" else { return [] }
        return (snapshot["rows"]["rows"].array ?? []).compactMap { message($0["row"]) }.sorted { $0.seq < $1.seq }
    }

    /// A snapshot frame or `conversation.snapshot` value as a page; nil
    /// without a head.
    func page(_ snapshot: HomeWireJSON) -> ConversationPage? {
        let messages = snapshotMessages(snapshot)
        guard let summary = summary(snapshot["state"], lastMessage: messages.last) else { return nil }
        return ConversationPage(conversation: summary, messages: messages,
                                threads: (snapshot["threads"].array ?? []).compactMap(threadSummary))
    }

    // MARK: Parts out

    /// The parts an op sends, in the owner's shape.
    func wire(_ parts: [MessagePart]) -> HomeWireJSON {
        .array(parts.map(wire))
    }

    func wire(_ part: MessagePart) -> HomeWireJSON {
        switch part {
        case .text(let text, let mentions):
            var fields: [String: HomeWireJSON] = ["type": "text", "text": .string(text)]
            if !mentions.isEmpty {
                fields["runs"] = .array(mentions.map {
                    ["start": .number(Double($0.start)), "length": .number(Double($0.length)), "mention": .string($0.participant.rawValue)]
                })
            }
            return .object(fields)
        case .work(let work):
            return .object(["type": "work", "session": .string(work.session), "host": .optional(work.host),
                            "status": .string(work.status.rawValue), "preview": .optional(work.preview)]
                .filter { !$0.value.isNull })
        case .attachment(let ref):
            var fields = (try? JSONEncoder().encode(ref)).flatMap(HomeWireJSON.parse)?.object ?? [:]
            fields["type"] = "attachment"
            return .object(fields)
        case .linkPreview(let link):
            var fields = (try? JSONEncoder().encode(link)).flatMap(HomeWireJSON.parse)?.object ?? [:]
            fields["type"] = "link_preview"
            return .object(fields)
        case .approval, .location, .question:
            // The owners take no approval or location parts from a person, and
            // a person never sends a question (agents post them).
            return ["type": "text", "text": .string(part.plainText)]
        }
    }

    func wire(_ reaction: Reaction.Kind) -> HomeWireJSON {
        switch reaction {
        case .tapback(let tapback): ["tapback": .string(tapback.rawValue)]
        case .emoji(let emoji): ["emoji": .string(emoji)]
        }
    }
}
