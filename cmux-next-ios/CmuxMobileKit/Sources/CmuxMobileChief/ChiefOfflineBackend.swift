import CmuxConversationCore
import Foundation

/// Chief with no Mac to talk to (no link yet, or the Mac does not offer
/// Chief): an empty conversation that reports itself disconnected and refuses
/// to send. The real Chief is `ChiefDaemonBackend`; the scripted mock exists
/// only in DEBUG builds with mock content on.
public final class ChiefOfflineBackend: ConversationBackend, Sendable {
    public let reason: String

    public init(reason: String = "Chief isn't connected to a Mac") {
        self.reason = reason
    }

    private var error: ConversationBackendError { ConversationBackendError(code: -1, message: reason) }

    public func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation.yield(.disconnected(reason: reason))
        return stream
    }

    public func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(messages: [], hasMore: false)
    }

    public func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage { throw error }
    public func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { throw error }
    public func edit(messageID: String, text: String) async throws -> ConversationMessage { throw error }
    public func unsend(messageID: String) async throws -> ConversationMessage { throw error }
    public func setTyping(_ isTyping: Bool) async {}
    public func markRead(upToSeq: Int) async {}
    public func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { throw error }
    public func close() {}
}
