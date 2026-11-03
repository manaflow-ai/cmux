import CmuxMobileAgentChat
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Agent-notification originals use the same file stream as the chat composer.
/// Build the prompt only after every upload succeeds; never silently omit a picked file.
enum PushReplyAttachments {
    @MainActor
    static func blocks(text: String, names: [String], outbox: PushOutbox?, link: (any MacLink)?) async throws -> [JSONValue] {
        let attachments = try await Task.detached(priority: .userInitiated) {
            try files(names, outbox: outbox)
        }.value
        var uploaded: [String: String] = [:]
        for attachment in attachments {
            guard let link else { throw LinkError(code: "offline", message: "Connect to send attachments.") }
            guard let url = attachment.fileURL else { throw PushOutbox.Refused() }
            do {
                uploaded[attachment.id] = try await LinkUpload.upload(fileAt: url, name: attachment.name, cwd: nil, over: link)
            } catch let failure as LinkUpload.Failure {
                // LinkUpload wraps transport errors. Restore their identity so notification
                // delivery offers Retry instead of treating a disconnect as a permanent refusal.
                switch failure.code {
                case "unreadable", "forbidden", "not_found", "not_regular_file", "unknown_service": throw failure
                default: throw LinkError(code: failure.code, message: failure.message)
                }
            }
        }
        return await Task.detached(priority: .userInitiated) {
            AcpmuxSessionSource.promptBlocks(text: text, attachments: attachments + previews(attachments), uploaded: uploaded)
        }.value
    }

    /// Vision previews are optional and bounded across the prompt. Every original above is
    /// uploaded regardless of format, size, decoder support or remaining preview space.
    nonisolated static func previews(_ files: [AgentAttachment]) -> [AgentAttachment] {
        var remaining = 1 << 20
        var result: [AgentAttachment] = []
        for file in files where remaining > 0 {
            guard let url = file.fileURL, let url = PushPickedFile.previewURL(url),
                  UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1024,
                  ] as CFDictionary) else { continue }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination), bytes.length <= remaining else { continue }
            remaining -= bytes.length
            result.append(AgentAttachment(kind: .image, name: file.name + " preview.jpg", data: bytes as Data))
        }
        return result
    }

    nonisolated static func files(_ names: [String], outbox: PushOutbox?) throws -> [AgentAttachment] {
        guard !names.isEmpty else { return [] }
        guard let outbox else { throw LinkUpload.Failure(code: "unreadable", message: "Couldn't open notification attachments.") }
        return try names.map { name in
            guard (name as NSString).lastPathComponent == name, !name.hasPrefix(".") else { throw PushOutbox.Refused() }
            let url = outbox.attachments.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
                throw LinkUpload.Failure(code: "unreadable", message: "Couldn't read \(name) on this iPhone.")
            }
            return AgentAttachment(kind: .file, name: name, fileURL: url, byteCount: size)
        }
    }
}
