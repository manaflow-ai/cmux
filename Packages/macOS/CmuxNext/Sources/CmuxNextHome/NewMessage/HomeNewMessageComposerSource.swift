public import CmuxHomeCore
public import Foundation
import CmuxNextHomeModel

/// The owner behind New Message's blank page: one empty conversation that
/// only exists on this Mac, so the page shows Home's own message box (the
/// same composer, glass and send motion as every conversation) before any
/// conversation exists. Nothing reaches a real owner from here except the
/// first send, which goes to `send`: the page makes the DM or group then
/// (Messages makes the conversation at the first send) and posts the text
/// there. Every other op is refused.
public struct HomeNewMessageComposerSource: HomeSource {
    /// The draft conversation's id (never an owner's id).
    public static let conversation = ConversationID("cmux.home.new-message")
    public let me: Participant
    /// The first send's parts; returns the real conversation's op result.
    public let send: @Sendable ([MessagePart]) async throws -> HomeOpResult

    /// Creates the source.
    /// - Parameters:
    ///   - me: The signed-in person (the draft conversation's only member).
    ///   - send: Makes the conversation and posts the parts there.
    public init(me: Participant, send: @escaping @Sendable ([MessagePart]) async throws -> HomeOpResult) {
        self.me = me
        self.send = send
    }

    /// The blank page's store, over Home's own attachment folder (`blobs`): it keeps no blobs of its own, so it
    /// never prunes that folder, whose drafts and pending sends Home's store keeps.
    @MainActor public func store(blobs: URL) -> HomeStore { // HomeStore is main-actor: both callers (HomeNewMessageView, its test) are
        HomeStore(source: self, blobCacheDirectory: blobs, prunesBlobCache: false)
    }

    private var summary: ConversationSummary {
        let start = Date(timeIntervalSince1970: 0)
        return ConversationSummary(id: Self.conversation, owner: .local, title: "", participants: [me], createdAt: start, updatedAt: start)
    }

    public func events() async -> AsyncStream<HomeEvent> {
        let snapshot = InboxSnapshot(me: me, conversations: [summary], rev: 1)
        // Two events, then nothing: a cap of two never drops one.
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            continuation.yield(.connection(.online))
            continuation.yield(.inbox(snapshot))
        }
    }

    public func inbox() async throws -> InboxSnapshot { InboxSnapshot(me: me, conversations: [summary], rev: 1) }

    public func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try Self.gate("composerSource.snapshot", Gate.Request(op: nil, conversation: conversation.rawValue))
        return ConversationPage(conversation: summary, messages: [])
    }

    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] { [] }

    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        guard case .sendMessage(let conversation, let parts, _, _) = intent.op else {
            try Self.gate("composerSource.submit", Gate.Request(op: "other", conversation: nil))
            throw HomeRejection.invalid("new_message.unsupported")
        }
        try Self.gate("composerSource.submit", Gate.Request(op: "sendMessage", conversation: conversation.rawValue))
        return try await send(parts)
    }

    public func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }

    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        throw HomeRejection.invalid("new_message.unsupported")
    }

    /// Runs one of the source's gates (`compose.composerSource.*`); its refusal throws as the owner's.
    private static func gate(_ op: String, _ request: Gate.Request) throws {
        let gate: Gate = HomeComposeRules().call(op, request, fallback: Gate(ok: false, invalid: "new_message.unsupported"))
        if !gate.ok { throw HomeRejection.invalid(gate.invalid ?? "new_message.unsupported") }
    }

    /// A gate's answer: through, or the `HomeRejection.invalid` reason.
    private struct Gate: Decodable {
        struct Request: Encodable {
            var op: String?
            var conversation: String?
        }

        var ok: Bool
        var invalid: String?
    }
}
