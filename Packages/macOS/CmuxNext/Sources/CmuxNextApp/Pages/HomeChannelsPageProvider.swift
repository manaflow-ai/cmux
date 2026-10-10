import AppKit
import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import Foundation

extension InternalPageID {
    static let homeChannels = InternalPageID(rawValue: "home-channels")
}

extension PageDescriptor {
    /// The channels Home (webviews/src/pages/home-channels): a React Home over the same Home owners
    /// the native Home reads. `cmux.home.` is granted to this first-party page only (an app page
    /// cannot claim a `cmux.` namespace, and no other descriptor lists it). Sends and reactions
    /// count only on the person's own gesture, so page script cannot post as the user on its own.
    static let homeChannels = PageDescriptor(
        id: "cmux.home-channels", resource: "home-channels", namespaces: ["cmux.home."])
}

extension PageFactory {
    /// The React channels Home when Debug Settings `home.surface` is `web`, else nil (the native
    /// Home). The tunable goes when one Home becomes the only one.
    func homeChannelsWebPage() -> PageWebView? {
        guard PageTunables.home.value == .web else { return nil }
        let home = services.home
        let provider = HomeChannelsPageProvider(source: home.homeRouter, me: ParticipantID(ConversationParticipant.localUserID))
        let routes = [PageRoute(prefix: "cmux.home.", provider: provider)]
        guard let page = PageWebView(descriptor: .homeChannels, routes: routes, surface: .home) else { return nil }
        home.homeDidOpen()
        return page
    }
}

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
            // The Home op vocabulary has no thread reply yet (backend request on cx-59n8).
            if params["threadRoot"]?.stringValue != nil {
                throw PageError(code: "cmux.home.threads_unavailable", message: "thread replies are not available yet")
            }
            let op = HomeOp.sendMessage(conversation: try Self.conversation(params), parts: [.text(text)])
            return try await HomeChannelsWire.submit(source, HomeIntent(key: try Self.key(params, context), op: op))
        case "cmux.home.react":
            try Self.requireGesture(context)
            guard let value = params["value"]?.stringValue, !value.isEmpty, value.count <= 8,
                  let message = params["message"]?.stringValue, !message.isEmpty else { throw PageError.invalidParams("value") }
            let op = HomeOp.addReaction(message: MessageID(message), conversation: try Self.conversation(params),
                                        reaction: .emoji(value), partIndex: max(0, params["partIndex"]?.intValue ?? 0))
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
