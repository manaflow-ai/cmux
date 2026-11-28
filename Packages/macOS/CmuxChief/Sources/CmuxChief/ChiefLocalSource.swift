public import CmuxHomeCore
public import Foundation

/// The ``HomeSource`` of the local Chief: Home's `HomeStore` reads and writes
/// the in-process ``ChiefConversationOwner`` through it.
///
/// Each ``events()`` call is its own subscription (several stores or views
/// may subscribe); every one starts with `.connection(.online)` and `.inbox`.
/// Contact lookups and invites are not supported locally.
///
/// A source can serve an owner that is still loading
/// (``init(loading:)``): the store connects when the load ends, and every
/// call waits for it. A failed load answers offline.
///
/// ```swift
/// let source = ChiefLocalSource(owner: owner)
/// let store = HomeStore(source: source)
/// store.start()
/// ```
public struct ChiefLocalSource: HomeSource {
    private let loadOwner: @Sendable () async throws -> ChiefConversationOwner

    /// Creates a source over `owner`.
    ///
    /// - Parameter owner: The conversation owner.
    public init(owner: ChiefConversationOwner) {
        loadOwner = { owner }
    }

    /// Creates a source over the owner `loading` makes
    /// (``ChiefConversationOwner/load(home:brain:userDisplayName:now:context:)``).
    ///
    /// - Parameter loading: The owner's load.
    public init(loading: Task<ChiefConversationOwner, any Error>) {
        loadOwner = { try await loading.value }
    }

    /// The owner, once loaded.
    ///
    /// - Throws: ``HomeRejection/ownerUnreachable`` when the load failed.
    public func owner() async throws -> ChiefConversationOwner {
        do {
            return try await loadOwner()
        } catch {
            throw HomeRejection.ownerUnreachable
        }
    }

    /// A new subscription to the owner's events. Waits for a loading owner;
    /// a failed load yields `.connection(.offline)` and ends.
    public func events() async -> AsyncStream<HomeEvent> {
        do {
            return try await owner().events()
        } catch {
            let (stream, continuation) = AsyncStream<HomeEvent>.makeStream()
            continuation.yield(.connection(.offline(since: Date())))
            continuation.finish()
            return stream
        }
    }

    /// The account inbox.
    public func inbox() async throws -> InboxSnapshot {
        try await owner().inbox()
    }

    /// The newest `tail` messages of a conversation.
    public func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try await owner().snapshot(of: conversation, tail: tail)
    }

    /// Up to `limit` messages before `beforeSeq`.
    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        try await owner().historyPage(of: conversation, before: beforeSeq, limit: limit).messages
    }

    /// Up to `limit` messages before `beforeSeq`, with thread stats.
    public func historyPage(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> HistoryPage {
        try await owner().historyPage(of: conversation, before: beforeSeq, limit: limit)
    }

    /// One page of a thread.
    public func thread(of conversation: ConversationID, root: MessageID, after afterSeq: Seq, limit: Int) async throws -> ThreadPage {
        try await owner().thread(of: conversation, root: root, after: afterSeq, limit: limit)
    }

    /// Applies an intent on the owner.
    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        try await owner().submit(intent)
    }

    /// Searches local Chief messages.
    public func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] {
        try await owner().search(query, limit: limit)
    }

    /// Always throws: the local Chief has no contacts.
    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        throw HomeRejection.invalid("unsupported")
    }

    /// Stores an attachment in the Chief home.
    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef {
        try await owner().upload(file)
    }

    /// The local file of an attachment variant.
    public func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        try await owner().fetch(ref, variant: variant)
    }
}
