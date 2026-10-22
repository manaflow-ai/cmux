import CmuxConversationCore
import Foundation

/// Audio messages to and from the Mac's Chief (user, 2026-10-21: "audio
/// messages dont work on ios and dont send to macos"). A recording goes up
/// as an `audio/mp4` attachment record with its `duration_ms`, and its
/// transcript goes as the message's text part: the Mac's Home shows it under
/// the player, and the Chief reads it as the message (the bytes are saved
/// for it too). Chief messages never expire, so Keep and the listened
/// report have nothing to change.
extension ChiefDaemonBackend: ConversationAudioBackend {
    public func uploadAudioRecording(_ data: Data, mimeType: String, info: ConversationAudioInfo) async throws -> ConversationAttachment {
        try await core.uploadAudio(data, mimeType: mimeType, info: info)
    }

    public func keepAudioMessage(messageID: String) async throws -> ConversationMessage {
        let page = try await core.history(beforeSeq: nil, limit: 200)
        guard let message = page.messages.first(where: { $0.id == messageID }) else {
            throw ConversationBackendError(code: -4, message: "no such message")
        }
        return message
    }

    public func markAudioPlayed(messageID: String) async {}
}
