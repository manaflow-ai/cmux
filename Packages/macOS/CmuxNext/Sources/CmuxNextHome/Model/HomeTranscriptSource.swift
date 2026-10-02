public import Foundation

/// A change the transcript applies to its window.
public nonisolated enum HomeTranscriptChange: Sendable {
    /// Confirmed messages after the previous newest, ascending.
    case appended([HomeMessage])
    /// A confirmed message changed (edit, retraction, reactions).
    case updated(HomeMessage)
    /// A send entered the intent log.
    case pendingAdded(HomeMessage)
    /// The owner confirmed a pending send: it becomes `confirmed` in place.
    case pendingResolved(clientMsgID: String, confirmed: HomeMessage)
    /// The owner rejected a pending send.
    case pendingFailed(clientMsgID: String, reason: String)
    /// Participants other than me who are typing now.
    case typing([String])
    /// The highest seq other participants have read (read cursor).
    case readThrough(Int)
    /// The mirror lost continuity (revision gap, reconnect): refetch.
    case reset
}

/// Stops a ``HomeTranscriptSource`` observation when cancelled or released.
@MainActor
public final class HomeObservation {
    private var onCancel: (@MainActor () -> Void)?

    public init(onCancel: @escaping @MainActor () -> Void) { self.onCancel = onCancel }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }

    isolated deinit { cancel() }
}

/// A paged mirror of one conversation (home.md section 3). The renderer keeps
/// at most a bounded window of it and never asks for the whole log.
/// Confirmed seqs are dense and ascending; pending messages always follow them.
@MainActor
public protocol HomeTranscriptSource: AnyObject {
    var conversationID: String { get }
    var participants: [HomeParticipant] { get }
    /// Newest confirmed seq, nil when the conversation is empty.
    var newestSeq: Int? { get }
    /// Oldest seq the owner still has.
    var oldestSeq: Int? { get }
    /// Sends not confirmed yet, oldest first.
    var pendingMessages: [HomeMessage] { get }
    /// Participants (not me) typing now.
    var typingParticipantIDs: [String] { get }
    /// The highest seq others have read, nil when unknown.
    var readThroughSeq: Int? { get }
    /// Confirmed messages with seq `< seq`, at most `limit`, ascending.
    func page(before seq: Int, limit: Int) async throws -> [HomeMessage]
    /// Calls `handler` for every change until the observation ends.
    func observe(_ handler: @escaping @MainActor (HomeTranscriptChange) -> Void) -> HomeObservation
}
