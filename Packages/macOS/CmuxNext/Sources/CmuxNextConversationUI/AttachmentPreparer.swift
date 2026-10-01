import AppKit
import CmuxConversation
import CryptoKit
import Foundation

/// Turns files the user picked into ``OutgoingAttachment``s: size, SHA-256
/// (streamed, off the main actor) and, for images, a small preview written
/// to a temp file. The original is never copied or re-encoded.
struct AttachmentPreparer: Sendable {
    let previewDirectory: URL

    func prepare(_ url: URL) async throws -> OutgoingAttachment {
        let (size, sha) = try await Task.detached(priority: .userInitiated) { () throws -> (UInt64, String) in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var total: UInt64 = 0
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                total += UInt64(chunk.count)
            }
            return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }.value
        let mime = Self.mimeType(url)
        let uploadID = "u-" + UUID().uuidString.lowercased()
        var attachment = OutgoingAttachment(uploadID: uploadID, fileURL: url, name: url.lastPathComponent, mimeType: mime, size: size, sha256: sha)
        if mime.hasPrefix("image/"), let preview = try? await thumbnail(url) {
            attachment.thumbnail = preview
        }
        return attachment
    }

    static func mimeType(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType) ?? "application/octet-stream"
    }

    private func thumbnail(_ url: URL) async throws -> OutgoingAttachment.Thumbnail? {
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        let scale = min(1, 256 / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = NSImage(size: size)
        small.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        let out = previewDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try jpeg.write(to: out)
        let sha = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        return OutgoingAttachment.Thumbnail(uploadID: "t-" + UUID().uuidString.lowercased(), fileURL: out, mimeType: "image/jpeg", size: UInt64(jpeg.count), sha256: sha)
    }
}
