import CmuxHomeCore
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Synchronization

/// The `cmux.home.*` wire of the channels Home page (webviews/src/pages/home-channels/types.ts):
/// the Home data the native Home reads (``HomeSource``), projected into page JSON. Every read and
/// its mapping runs off the main actor (`@concurrent`); the main actor only hands the finished
/// value to the page. Pages are bounded (``maxPage``), so no call maps a whole transcript.
nonisolated enum HomeChannelsWire {
    static let maxPage = 200
    static let maxText = 40_000

    @concurrent static func inbox(_ source: any HomeSource) async throws -> (JSONValue, ParticipantID) {
        let inbox = try await rejecting { try await source.inbox() }
        let me = inbox.me.id
        let value: JSONValue = .object([
            "me": participant(inbox.me),
            "conversations": .array(inbox.conversations.map { conversation($0, me: me) }),
            "rev": number(inbox.rev),
        ])
        return (value, me)
    }

    @concurrent static func page(_ source: any HomeSource, conversation id: ConversationID, tail: Int, me: ParticipantID) async throws -> JSONValue {
        let page = try await rejecting { try await source.snapshot(of: id, tail: tail) }
        return .object([
            "conversation": conversation(page.conversation, me: me),
            "messages": .array(page.messages.map(message)),
        ])
    }

    @concurrent static func history(_ source: any HomeSource, conversation id: ConversationID, before: Seq, limit: Int) async throws -> JSONValue {
        let messages = try await rejecting { try await source.history(of: id, before: before, limit: limit) }
        return .object(["messages": .array(messages.map(message))])
    }

    @concurrent static func search(_ source: any HomeSource, query: String, limit: Int) async throws -> JSONValue {
        let hits = try await rejecting { try await source.search(query, limit: limit) }
        return .object(["hits": .array(hits.map { .object(["conversation": .string($0.conversation.rawValue), "message": message($0.message)]) })])
    }

    @concurrent static func submit(_ source: any HomeSource, _ intent: HomeIntent) async throws -> JSONValue {
        let result = try await rejecting { try await source.submit(intent) }
        return .object(["rev": number(result.rev), "replayed": .bool(result.replayed)])
    }

    /// Runs one owner call, turning the owner's refusals into page errors.
    private static func rejecting<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let rejection as HomeRejection {
            throw pageError(rejection)
        } catch is HomeOwnerOffline {
            throw PageError.unavailable("Home is offline")
        }
    }

    static func pageError(_ rejection: HomeRejection) -> PageError {
        switch rejection {
        case .ownerUnreachable: PageError.unavailable("the Home owner is unreachable")
        case .notAuthorized: PageError(code: "cmux.home.not_authorized", message: "not authorized")
        case .invalid(let message): PageError.invalidParams(message)
        case .rateLimited: PageError(code: "cmux.home.rate_limited", message: "rate limited", retryable: true)
        case .indeterminate: PageError(code: "cmux.home.indeterminate", message: "the owner did not answer", retryable: true)
        }
    }

    // MARK: Mapping

    static func number(_ value: UInt64) -> JSONValue { .number(Double(value)) }
    static func millis(_ date: Date) -> JSONValue { .number((date.timeIntervalSince1970 * 1000).rounded()) }

    static func participant(_ participant: Participant) -> JSONValue {
        .object([
            "id": .string(participant.id.rawValue),
            "kind": .string(participant.kind.rawValue),
            "name": .string(participant.displayName),
            "chief": .bool(participant.isChief),
        ])
    }

    static func conversation(_ summary: ConversationSummary, me: ParticipantID) -> JSONValue {
        let kind: String = switch summary.kind(me: me) {
        case .chief: "chief"
        case .direct: "direct"
        case .group: "group"
        }
        var members: [String: JSONValue] = [
            "id": .string(summary.id.rawValue),
            "owner": .string(summary.owner.rawValue),
            "title": .string(summary.title),
            "kind": .string(kind),
            "participants": .array(summary.participants.map(participant)),
            "lastSeq": number(summary.lastSeq),
            "rev": number(summary.rev),
            "updatedAt": millis(summary.updatedAt),
            "unread": JSONValue(summary.unreadCount(me: me)),
            "mentions": JSONValue(summary.mentionCount),
            "muted": .bool(summary.muted),
            "pinned": .bool(summary.pinRank != nil),
        ]
        if let last = summary.lastMessage { members["lastText"] = .string(String(last.plainText.prefix(200))) }
        return .object(members)
    }

    static func message(_ message: Message) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(message.id.rawValue),
            "conversation": .string(message.conversation.rawValue),
            "seq": number(message.seq),
            "author": .string(message.author.rawValue),
            "createdAt": millis(message.createdAt),
            "retracted": .bool(message.isRetracted),
            "parts": .array(message.isRetracted ? [] : message.parts.map(part)),
            "reactions": .array(message.reactions.map(reaction)),
        ]
        if let edited = message.editedAt { members["editedAt"] = millis(edited) }
        if let reply = message.replyTo {
            members["replyTo"] = .object(["message": .string(reply.message.rawValue), "partIndex": JSONValue(reply.partIndex)])
        }
        if let root = message.threadRoot { members["threadRoot"] = .string(root.rawValue) }
        return .object(members)
    }

    static func part(_ part: MessagePart) -> JSONValue {
        switch part {
        case .text(let text, let mentions):
            return .object([
                "type": .string("text"),
                "text": .string(text),
                "mentions": .array(mentions.map {
                    .object(["start": JSONValue($0.start), "length": JSONValue($0.length), "participant": .string($0.participant.rawValue)])
                }),
            ])
        case .work(let work):
            var members: [String: JSONValue] = ["type": .string("work"), "title": .string(work.title), "status": .string(work.status.rawValue)]
            if let preview = work.preview { members["preview"] = .string(preview) }
            return .object(members)
        case .attachment(let file):
            return .object([
                "type": .string("attachment"), "name": .string(file.name), "mimeType": .string(file.mimeType),
                "byteCount": JSONValue(file.byteCount), "hash": .string(file.hash),
            ])
        case .approval, .question, .linkPreview, .location:
            return .object(["type": .string("other"), "text": .string(part.plainText)])
        }
    }

    static func reaction(_ reaction: Reaction) -> JSONValue {
        let value: String = switch reaction.kind {
        case .emoji(let emoji): emoji
        case .tapback(let tapback): tapbackEmoji[tapback] ?? tapback.rawValue
        }
        return .object(["author": .string(reaction.author.rawValue), "partIndex": JSONValue(reaction.partIndex), "value": .string(value)])
    }

    static let tapbackEmoji: [Reaction.Tapback: String] = [
        .love: "❤️", .like: "👍", .dislike: "👎", .laugh: "😂", .emphasize: "‼️", .question: "❓",
    ]
}

/// Coalesces owner events into one pending batch for the page: the event loop (off the main
/// actor) maps each event into the batch, and only the first event after a delivery schedules a
/// main-actor hop, so a burst of events costs one hop and one page message, never one per event.
/// A batch that grows past ``maxMessages`` drops its messages and marks the conversations stale,
/// so the page refetches one bounded page instead.
nonisolated final class HomeChannelsEventPump: Sendable {
    static let maxMessages = 300

    private struct Pending {
        var connection: String?
        var inboxStale = false
        var conversations: [String: JSONValue] = [:]
        var removed: Set<String> = []
        var messages: [String: JSONValue] = [:]
        var messageOrder: [String] = []
        var stale: Set<String> = []
        var typing: [JSONValue] = []
        var scheduled = false

        var isEmpty: Bool {
            connection == nil && !inboxStale && conversations.isEmpty && removed.isEmpty && messages.isEmpty && stale.isEmpty && typing.isEmpty
        }
    }

    private let state = Mutex(Pending())
    private let cancelled = Mutex(false)

    /// The subscription ended: a delivery already scheduled hands the page nothing.
    func cancel() {
        cancelled.withLock { $0 = true }
    }
    private let me: Mutex<ParticipantID>

    init(me: ParticipantID) {
        self.me = Mutex(me)
    }

    func setMe(_ id: ParticipantID) {
        me.withLock { $0 = id }
    }

    /// Adds one event; true when the caller must schedule a delivery (none is pending).
    func add(_ event: HomeEvent) -> Bool {
        let me = me.withLock { $0 }
        return state.withLock { pending in
            switch event {
            case .connection(let connection):
                pending.connection = switch connection {
                case .connecting: "connecting"
                case .online: "online"
                case .offline: "offline"
                }
            case .inbox, .ownerRecovered:
                pending.inboxStale = true
            case .conversationChanged(let summary, _, _):
                pending.conversations[summary.id.rawValue] = HomeChannelsWire.conversation(summary, me: me)
                pending.removed.remove(summary.id.rawValue)
            case .conversationRemoved(let id, _):
                pending.conversations.removeValue(forKey: id.rawValue)
                pending.removed.insert(id.rawValue)
            case .message(let message, _):
                let key = message.id.rawValue
                if pending.messages[key] == nil { pending.messageOrder.append(key) }
                pending.messages[key] = HomeChannelsWire.message(message)
                if pending.messages.count > Self.maxMessages {
                    for value in pending.messages.values {
                        if let conversation = value["conversation"]?.stringValue { pending.stale.insert(conversation) }
                    }
                    pending.messages.removeAll()
                    pending.messageOrder.removeAll()
                }
            case .conversationPage(let page):
                pending.conversations[page.conversation.id.rawValue] = HomeChannelsWire.conversation(page.conversation, me: me)
                pending.stale.insert(page.conversation.id.rawValue)
            case .intentsRevoked:
                break
            case .typing(let conversation, let participant, let on):
                pending.typing.append(.object([
                    "conversation": .string(conversation.rawValue), "participant": .string(participant.rawValue), "on": .bool(on),
                ]))
            }
            guard !pending.scheduled, !pending.isEmpty else { return false }
            pending.scheduled = true
            return true
        }
    }

    /// Takes the pending batch (nil when empty) and lets the next event schedule again.
    func take() -> JSONValue? {
        guard !cancelled.withLock({ $0 }) else { return nil }
        let pending = state.withLock { pending in
            let taken = pending
            pending = Pending()
            return taken
        }
        guard !pending.isEmpty else { return nil }
        var batch: [String: JSONValue] = [:]
        if let connection = pending.connection { batch["connection"] = .string(connection) }
        if pending.inboxStale { batch["inboxStale"] = .bool(true) }
        if !pending.conversations.isEmpty { batch["conversations"] = .array(Array(pending.conversations.values)) }
        if !pending.removed.isEmpty { batch["removed"] = .array(pending.removed.map { .string($0) }) }
        if !pending.messageOrder.isEmpty { batch["messages"] = .array(pending.messageOrder.compactMap { pending.messages[$0] }) }
        if !pending.stale.isEmpty { batch["stale"] = .array(pending.stale.map { .string($0) }) }
        if !pending.typing.isEmpty { batch["typing"] = .array(pending.typing) }
        return .object(batch)
    }
}
