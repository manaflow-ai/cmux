public import Foundation

/// A `HomeSource` over another one that can hold transcript reads until a
/// test lets them go, and records each read and close. Tests use it to
/// check that every `HomeStore.open` pairs with one `close`, also while a
/// first page loads.
public final class GatedHomeSource: HomeSource, @unchecked Sendable {
    private let inner: any HomeSource
    private let lock = NSLock()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var reads: [ConversationID] = []
    private var closed: [ConversationID] = []
    private var steps: [Step] = []

    /// One read starting or returning, or one close, in the order they ran.
    public enum Step: Hashable, Sendable {
        case read(ConversationID)
        case readReturned(ConversationID)
        case close(ConversationID)
    }

    public init(_ inner: any HomeSource) {
        self.inner = inner
    }

    /// Every transcript read so far (`snapshot(of:tail:)`), in order.
    public var snapshots: [ConversationID] { lock.withLock { reads } }
    /// Every `close` so far, in order.
    public var closes: [ConversationID] { lock.withLock { closed } }
    /// Every read start, read return and close so far, in order.
    public var journal: [Step] { lock.withLock { steps } }
    /// Reads waiting for `release()` now.
    public var waiting: Int { lock.withLock { held.count } }

    /// Holds every later transcript read until `release()`.
    public func hold() {
        lock.withLock { holding = true }
    }

    /// Lets every held read go, and stops holding.
    public func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            defer { held = [] }
            return held
        }
        for waiter in waiters { waiter.resume() }
    }

    public func events() async -> AsyncStream<HomeEvent> { await inner.events() }
    public func inbox() async throws -> InboxSnapshot { try await inner.inbox() }

    public func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                reads.append(conversation)
                steps.append(.read(conversation))
                if holding { held.append(continuation) }
                return holding
            }
            if !wait { continuation.resume() }
        }
        defer { lock.withLock { steps.append(.readReturned(conversation)) } }
        return try await inner.snapshot(of: conversation, tail: tail)
    }

    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        try await inner.history(of: conversation, before: beforeSeq, limit: limit)
    }

    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await inner.submit(intent) }
    public func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { try await inner.search(query, limit: limit) }
    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await inner.resolve(contact) }
    public func upload(_ file: AttachmentUpload) async throws -> AttachmentRef { try await inner.upload(file) }

    public func fetch(_ ref: AttachmentRef, at location: AttachmentLocation, variant: AttachmentVariant) async throws -> URL {
        try await inner.fetch(ref, at: location, variant: variant)
    }

    public func close(_ conversation: ConversationID) {
        lock.withLock {
            closed.append(conversation)
            steps.append(.close(conversation))
        }
        inner.close(conversation)
    }
}
