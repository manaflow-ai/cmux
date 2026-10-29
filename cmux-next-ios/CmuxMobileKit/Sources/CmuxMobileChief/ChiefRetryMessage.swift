import CmuxConversationCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rebuild a failed Chief turn's input without inventing text or dropping attachments.
/// A partially loaded message stays available for retry once its bytes arrive.
struct ChiefRetryMessage {
    let message: ConversationMessage
    var images: [ConversationComposeImage] = []
    var files: [ConversationPendingFile] = []
    var audio: (data: Data, info: ConversationAudioInfo)?

    init?(_ message: ConversationMessage) {
        self.message = message
        for attachment in message.attachments {
            guard let data = attachment.localData else { return nil }
            switch attachment.kind {
            case .image:
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let type = CGImageSourceGetType(source),
                      let mime = UTType(type as String)?.preferredMIMEType else { return nil }
                images.append(ConversationComposeImage(data: data, width: attachment.width,
                                                       height: attachment.height, mimeType: mime))
            case .file:
                guard let info = attachment.file else { return nil }
                files.append(ConversationPendingFile(data: data, info: info))
            case .audio:
                // The conversation API sends an audio recording as its own message.
                guard message.attachments.count == 1, message.text.isEmpty,
                      let info = attachment.audio, !data.isEmpty else { return nil }
                audio = (data, info)
            }
        }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !message.attachments.isEmpty else { return nil }
    }

    @MainActor
    func send(to store: ConversationStore) -> Bool {
        if let audio {
            return store.sendAudio(data: audio.data, info: audio.info, replyToID: message.replyToID) != nil
        }
        return store.send(text: message.text,
                          images: images.map { ($0.data, $0.width, $0.height, $0.mimeType) },
                          replyToID: message.replyToID, mentions: message.mentions,
                          textRuns: message.textRuns, linkPreview: message.linkPreview,
                          effect: message.effect, files: files) != nil
    }
}
