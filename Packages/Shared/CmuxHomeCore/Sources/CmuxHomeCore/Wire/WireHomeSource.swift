public import Foundation

/// A ``HomeSource`` that will speak the hosted `cmux.wire/1` protocol
/// directly (plans/cmux-next/dm-group-chat-DESIGN.md sections 4.3 and 4.5).
/// Not implemented yet: every read and op refuses, and no socket is dialed.
public actor WireHomeSource: HomeSource {
    /// The signed-in user as the server knows them; nil until the server said who.
    var me: Participant?

    public init(baseURL: URL, auth: HomeWireAuth, displayName: String = "", http: any HomeWireHTTP,
                sockets: any HomeWireSocketConnecting, clock: any Clock<Duration> = ContinuousClock(),
                fetchDirectory: URL = FileManager.default.temporaryDirectory) {}

    /// Ends every socket and every event stream.
    public func shutdown() async {}

    public func events() async -> AsyncStream<HomeEvent> {
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream()
        continuation.yield(.connection(.connecting))
        return stream
    }

    public func inbox() async throws -> InboxSnapshot { throw HomeRejection.ownerUnreachable }
    public func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage { throw HomeRejection.ownerUnreachable }
    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] { [] }
    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult { throw HomeRejection.ownerUnreachable }
    public func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }
    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }
}
