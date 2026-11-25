public import CmuxHomeCore
public import Foundation

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
        guard conversation == Self.conversation else { throw HomeRejection.invalid("new_message.unknown_conversation") }
        return ConversationPage(conversation: summary, messages: [])
    }

    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] { [] }

    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        guard case .sendMessage(let conversation, let parts, _, _) = intent.op, conversation == Self.conversation else {
            throw HomeRejection.invalid("new_message.unsupported")
        }
        return try await send(parts)
    }

    public func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }

    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        throw HomeRejection.invalid("new_message.unsupported")
    }
}
