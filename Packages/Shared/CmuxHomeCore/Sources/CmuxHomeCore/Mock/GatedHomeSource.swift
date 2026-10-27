import CmuxSafeConcurrency
public import Foundation

/// A `HomeSource` over another one that can hold transcript reads until a
/// test lets them go, and records each read and close. Tests use it to
/// check that every `HomeStore.open` pairs with one `close`, also while a
/// first page loads.
public final class GatedHomeSource: HomeSource, Sendable {
    private let inner: any HomeSource
    private let state = Mutex(State())

    /// Everything the reads and closes change, reached only under the mutex.
    private struct State {
        var holding = false
        var held: [OnceContinuation<Void, OnceContinuationError>] = []
        var reads: [ConversationID] = []
        var closed: [ConversationID] = []
        var steps: [Step] = []
    }

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
    public var snapshots: [ConversationID] { state.withLock { $0.reads } }
    /// Every `close` so far, in order.
    public var closes: [ConversationID] { state.withLock { $0.closed } }
    /// Every read start, read return and close so far, in order.
    public var journal: [Step] { state.withLock { $0.steps } }
    /// Reads waiting for `release()` now.
    public var waiting: Int { state.withLock { $0.held.count } }

    /// Holds every later transcript read until `release()`.
    public func hold() {
        state.withLock { $0.holding = true }
    }

    /// Lets every held read go, and stops holding.
    public func release() {
        let waiters = state.withLock { state -> [OnceContinuation<Void, OnceContinuationError>] in
            state.holding = false
            defer { state.held = [] }
            return state.held
        }
        for waiter in waiters { waiter.resume(returning: ()) }
    }

    public func events() async -> AsyncStream<HomeEvent> { await inner.events() }
    public func inbox() async throws -> InboxSnapshot { try await inner.inbox() }

    public func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            let wait = state.withLock { state -> Bool in
                state.reads.append(conversation)
                state.steps.append(.read(conversation))
                if state.holding { state.held.append(continuation) }
                return state.holding
            }
            if !wait { continuation.resume(returning: ()) }
        }
        defer { state.withLock { $0.steps.append(.readReturned(conversation)) } }
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
        state.withLock { state in
            state.closed.append(conversation)
            state.steps.append(.close(conversation))
        }
        inner.close(conversation)
    }
}
