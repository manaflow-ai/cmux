import AppKit
import CmuxHomeCore
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Serves `cmux.home.*` for the channels Home page from a ``HomeSource`` (the app's
/// ``HomeSourceRouter``: the local conversation owner plus the Cloud owners). It keeps no Home
/// state of its own: reads go to the owners, writes are intents with the page's idempotency key,
/// and events reach the page as coalesced batches (``HomeChannelsEventPump``). Owner calls and
/// JSON mapping run off the main actor (``HomeChannelsWire``).
@MainActor
final class HomeChannelsPageProvider: PageProvider {
    private let source: any HomeSource
    private var me: ParticipantID
    private var pumps: [ObjectIdentifier: HomeChannelsEventPump] = [:]

    init(source: any HomeSource, me: ParticipantID) {
        self.source = source
        self.me = me
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let source = source
        switch op {
        case "cmux.home.inbox":
            let (value, me) = try await HomeChannelsWire.inbox(source)
            self.me = me
            for pump in pumps.values { pump.setMe(me) }
            return value
        case "cmux.home.page":
            let tail = Self.bounded(params["tail"]?.intValue, default: 100)
            return try await HomeChannelsWire.page(source, conversation: try Self.conversation(params), tail: tail, me: me)
        case "cmux.home.history":
            guard let before = params["beforeSeq"]?.intValue, before > 0 else { throw PageError.invalidParams("beforeSeq") }
            let limit = Self.bounded(params["limit"]?.intValue, default: 100)
            return try await HomeChannelsWire.history(source, conversation: try Self.conversation(params), before: Seq(before), limit: limit)
        case "cmux.home.search":
            guard let query = params["query"]?.stringValue, !query.isEmpty, query.count <= 200 else { throw PageError.invalidParams("query") }
            return try await HomeChannelsWire.search(source, query: query, limit: min(Self.bounded(params["limit"]?.intValue, default: 20), 50))
        case "cmux.home.read":
            guard let seq = params["seq"]?.intValue, seq >= 0 else { throw PageError.invalidParams("seq") }
            let op = HomeOp.setReadCursor(conversation: try Self.conversation(params), seq: Seq(seq))
            return try await HomeChannelsWire.submit(source, HomeIntent(key: try Self.key(params, context), op: op))
        case "cmux.home.send":
            try Self.requireGesture(context)
            guard let text = params["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= HomeChannelsWire.maxText else { throw PageError.invalidParams("text") }
            let root = try Self.optionalMessage(params["threadRoot"])
            let op = HomeOp.sendMessage(conversation: try Self.conversation(params), parts: [.text(text)], threadRoot: root)
            return try await HomeChannelsWire.submit(source, HomeIntent(key: try Self.key(params, context), op: op))
        case "cmux.home.react":
            try Self.requireGesture(context)
            guard let value = params["value"]?.stringValue, !value.isEmpty, value.count <= 8,
                  let message = params["message"]?.stringValue, !message.isEmpty else { throw PageError.invalidParams("value") }
            // A tapback comes back by its name, so the page can take back the reaction it shows.
            let kind: Reaction.Kind = params["tapback"]?.stringValue.flatMap(Reaction.Tapback.init(rawValue:)).map { .tapback($0) }
                ?? .emoji(value)
            let conversation = try Self.conversation(params)
            let partIndex = max(0, params["partIndex"]?.intValue ?? 0)
            let op: HomeOp = params["remove"]?.boolValue == true
                ? .removeReaction(message: MessageID(message), conversation: conversation, reaction: kind, partIndex: partIndex)
                : .addReaction(message: MessageID(message), conversation: conversation, reaction: kind, partIndex: partIndex)
            return try await HomeChannelsWire.submit(source, HomeIntent(key: try Self.key(params, context), op: op))
        case "cmux.home.edit":
            try Self.requireGesture(context)
            guard let text = params["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= HomeChannelsWire.maxText else { throw PageError.invalidParams("text") }
            guard let message = try Self.optionalMessage(params["message"]) else { throw PageError.invalidParams("message") }
            let op = HomeOp.editMessage(message: message, conversation: try Self.conversation(params), parts: [.text(text)])
            return try await HomeChannelsWire.submit(source, HomeIntent(key: try Self.key(params, context), op: op))
        case "cmux.home.retract":
            try Self.requireGesture(context)
            guard let message = try Self.optionalMessage(params["message"]) else { throw PageError.invalidParams("message") }
            let op = HomeOp.retractMessage(message: message, conversation: try Self.conversation(params))
            return try await HomeChannelsWire.submit(source, HomeIntent(key: try Self.key(params, context), op: op))
        default:
            throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.home.events" else { throw PageError.unknownOp(stream) }
        let pump = HomeChannelsEventPump(me: me)
        let source = source
        let id = ObjectIdentifier(pump)
        pumps[id] = pump
        // task-owner: the page's subscription; cancelled by the PageSubscription below.
        let task = Task.detached {
            for await event in await source.events() {
                guard pump.add(event) else { continue }
                // One hop per batch: the next event schedules again only after this take.
                // task-owner: one delivery; it ends after handing the batch to the page.
                Task { @MainActor in
                    if let batch = pump.take() { onEvent(batch) }
                }
            }
        }
        return PageSubscription { [weak self] in
            task.cancel()
            pump.cancel()
            self?.pumps.removeValue(forKey: id)
        }
    }

    /// A message id param: nil when absent, refused when present but not a short string.
    private static func optionalMessage(_ value: JSONValue?) throws -> MessageID? {
        guard let value, !value.isNull else { return nil }
        guard let id = value.stringValue, !id.isEmpty, id.count <= 256 else { throw PageError.invalidParams("message") }
        return MessageID(id)
    }

    private static func conversation(_ params: JSONValue) throws -> ConversationID {
        guard let id = params["conversation"]?.stringValue, !id.isEmpty, id.count <= 256 else { throw PageError.invalidParams("conversation") }
        return ConversationID(id)
    }

    /// The page's idempotency key (or its operation id), so a resend applies once.
    private static func key(_ params: JSONValue, _ context: PageCallContext) throws -> IdempotencyKey {
        guard let key = params["idempotencyKey"]?.stringValue ?? context.opid, PageCallContext.isValidOpid(key) else {
            throw PageError.invalidParams("idempotencyKey")
        }
        return IdempotencyKey(key)
    }

    private static func requireGesture(_ context: PageCallContext) throws {
        guard context.userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: "needs the person's own gesture") }
    }

    private static func bounded(_ value: Int?, default fallback: Int) -> Int {
        min(max(value ?? fallback, 1), HomeChannelsWire.maxPage)
    }
}
