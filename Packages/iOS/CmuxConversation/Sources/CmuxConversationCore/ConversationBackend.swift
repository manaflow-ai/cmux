import Foundation

/// What a backend reports to the store. A backend owns its transport,
/// reconnects on its own, and resumes from the last event it delivered.
public enum ConversationBackendEvent: Sendable {
    /// The session is (re)established. `lagged` means events were missed and
    /// cannot be replayed; the store must refetch the newest page.
    case connected(info: ConversationInfo, meID: String, lagged: Bool)
    /// A created or changed message, at a per-conversation event sequence.
    /// Duplicates are possible; the store dedupes on `eventSeq`.
    case message(ConversationMessage, eventSeq: Int)
    case typing(participantID: String, isTyping: Bool)
    case disconnected(reason: String)
}

public struct ConversationBackendError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
}

/// The seam between the transcript and any chat backend (acpmux, the
/// conversation simulator, a cloud relay). Everything above it is
/// backend-agnostic.
public protocol ConversationBackend: AnyObject, Sendable {
    /// Starts the session. The stream lives until `close()`.
    func events() -> AsyncStream<ConversationBackendEvent>
    /// `beforeSeq == nil` returns the newest page. Messages ascend by seq.
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage
    /// Idempotent on `draft.clientMessageID`.
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage
    /// Replaces the text of one of my messages.
    func edit(messageID: String, text: String) async throws -> ConversationMessage
    func setTyping(_ isTyping: Bool) async
    func markRead(upToSeq: Int) async
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment
    func close()
}
