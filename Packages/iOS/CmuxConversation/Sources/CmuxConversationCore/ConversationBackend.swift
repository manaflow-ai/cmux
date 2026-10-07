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
    /// The read marker moved (any device read or sent) or the session began.
    case readState(ConversationReadState)
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
    /// Takes back one of my messages (Undo Send). The result carries `unsentAt`.
    func unsend(messageID: String) async throws -> ConversationMessage
    /// Replaces the text and its formatting (an empty `textRuns` clears it).
    func edit(messageID: String, text: String, textRuns: [ConversationTextRun]) async throws -> ConversationMessage
    func setTyping(_ isTyping: Bool) async
    func markRead(upToSeq: Int) async
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment
    func close()
}

extension ConversationBackend {
    /// Backends without rich text drop the formatting.
    public func edit(messageID: String, text: String, textRuns: [ConversationTextRun]) async throws -> ConversationMessage {
        try await edit(messageID: messageID, text: text)
    }
}
/// Audio messages. Optional for backends: the defaults refuse, so a backend
/// without audio support keeps compiling and the UI reports the failure.
extension ConversationBackend {
    /// Uploads a recording. `waveform` holds peak levels in 0...1.
    public func uploadAudio(_ data: Data, mimeType: String, info: ConversationAudioInfo) async throws -> ConversationAttachment {
        if let audio = self as? any ConversationAudioBackend {
            return try await audio.uploadAudioRecording(data, mimeType: mimeType, info: info)
        }
        throw ConversationBackendError(code: -1, message: "audio messages are not supported")
    }

    /// Keeps an audio message that would otherwise expire on this device.
    public func keepAudio(messageID: String) async throws -> ConversationMessage {
        if let audio = self as? any ConversationAudioBackend {
            return try await audio.keepAudioMessage(messageID: messageID)
        }
        throw ConversationBackendError(code: -1, message: "audio messages are not supported")
    }

    /// The reader finished listening; the backend starts the expiry clock.
    public func audioPlayed(messageID: String) async {
        if let audio = self as? any ConversationAudioBackend {
            await audio.markAudioPlayed(messageID: messageID)
        }
    }
}

/// Backends that carry audio messages adopt this beside `ConversationBackend`.
public protocol ConversationAudioBackend: ConversationBackend {
    func uploadAudioRecording(_ data: Data, mimeType: String, info: ConversationAudioInfo) async throws -> ConversationAttachment
    func keepAudioMessage(messageID: String) async throws -> ConversationMessage
    func markAudioPlayed(messageID: String) async
}
