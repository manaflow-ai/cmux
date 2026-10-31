import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextPhone
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// "Send to Chief": posts a phone recording into the Chief conversation as
/// one message, the summary text plus the video (with its poster frame), on
/// the Chief owner's daemon. The Chief reads it like any message with an
/// attachment.
@MainActor
final class PhoneChiefFeedback: PhoneFeedbackSink {
    private weak var home: HomeService?

    init(home: HomeService) { self.home = home }

    func send(_ clip: PhoneFeedbackClip) async throws {
        guard let connection = home?.chief.connection,
              home?.chief.supports(DaemonCapability.localConversations.rawValue) == true else {
            throw PhoneFeedbackError.chiefNotRunning
        }
        let client = ConversationClient(connection)
        guard let conversation = HomeChiefName.select(from: try await client.list())?.id else {
            throw PhoneFeedbackError.chiefNotRunning
        }
        var parts: [ConversationPart] = [.text(clip.markdown, runs: [])]
        if await ConversationClient.supportsAttachments(connection) {
            let video = try await Self.upload(clip.recording, to: conversation, client: client)
            parts.append(.attachment(video))
        }
        let key = "phone-feedback:" + clip.recording.id
        _ = try await client.op(ConversationOpRequest(conversation: conversation, idempotencyKey: key,
                                                      transaction: ClientTransactionID(rawValue: key),
                                                      op: .send(clientMsgID: key, parts: parts, replyTo: nil)))
    }

    /// Uploads the video with a JPEG poster (the owner stores video posters as JPEG or WebP).
    nonisolated private static func upload(_ recording: PhoneRecording, to conversation: String,
                                           client: ConversationClient) async throws -> ConversationAttachment {
        let video = recording.videoURL
        let poster = recording.posterURL.flatMap { jpeg(from: $0, next: recording.folder.appendingPathComponent("poster.jpg")) }
        let posterImage = try poster.map { url in
            let data = try Data(contentsOf: url)
            return ConversationDerivedImage(hash: sha256(data), mimeType: "image/jpeg", byteCount: data.count)
        }
        let (hash, size) = try sha256(file: video)
        let attachment = ConversationAttachment(
            hash: hash, name: "\(recording.device.name) \(recording.id).\(video.pathExtension)",
            mimeType: video.pathExtension == "mp4" ? "video/mp4" : "video/quicktime", byteCount: size,
            durationMs: Int(recording.duration * 1000), poster: posterImage)
        _ = try await client.uploadAttachment(conversation: conversation, attachment: attachment, file: video, posterFile: poster)
        return attachment
    }

    nonisolated private static func jpeg(from png: URL, next target: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? target : nil
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a file in 4 MiB reads (a recording can be hundreds of MB).
    nonisolated private static func sha256(file: URL) throws -> (String, Int) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

/// Why "Send to Chief" could not post.
enum PhoneFeedbackError: Error, CustomStringConvertible {
    case chiefNotRunning

    var description: String {
        String(localized: "phone.feedback.chiefNotRunning", defaultValue: "Chief is not running. The recording is saved; send it again later.",
               table: "Phone", bundle: .module)
    }
}
