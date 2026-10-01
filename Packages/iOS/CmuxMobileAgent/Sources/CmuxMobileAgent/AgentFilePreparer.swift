import CmuxConversation
import CryptoKit
import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Turns picked photos and files into ``OutgoingAttachment``s: the bytes are
/// written once into the app's own folder (a picked item is not a file the
/// app may reopen later), hashed, and, for images, given a small preview.
/// The original bytes are never re-encoded or downscaled.
struct AgentFilePreparer: Sendable {
    let directory: URL

    func prepare(data: Data, suggestedName: String, type: UTType?) async throws -> OutgoingAttachment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = type?.preferredFilenameExtension.map { "." + $0 } ?? ""
        let name = suggestedName.isEmpty ? "attachment\(ext)" : suggestedName
        let url = directory.appendingPathComponent(UUID().uuidString + "-" + name)
        try data.write(to: url)
        return try await prepare(url: url, name: name, type: type)
    }

    func prepare(fileAt source: URL) async throws -> OutgoingAttachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: source.pathExtension)
        return try await prepare(url: url, name: source.lastPathComponent, type: type)
    }

    private func prepare(url: URL, name: String, type: UTType?) async throws -> OutgoingAttachment {
        let (size, sha) = try await Task.detached { () throws -> (UInt64, String) in
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
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        var attachment = OutgoingAttachment(uploadID: "u-" + UUID().uuidString.lowercased(), fileURL: url, name: name, mimeType: mime, size: size, sha256: sha)
        attachment.thumbnail = thumbnail(url: url, mime: mime)
        return attachment
    }

    private func thumbnail(url: URL, mime: String) -> OutgoingAttachment.Thumbnail? {
        #if canImport(UIKit)
        guard mime.hasPrefix("image/"), let image = UIImage(contentsOfFile: url.path) else { return nil }
        let scale = min(1, 256 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.7) else { return nil }
        let out = directory.appendingPathComponent(UUID().uuidString + "-thumb.jpg")
        guard (try? jpeg.write(to: out)) != nil else { return nil }
        let sha = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        return OutgoingAttachment.Thumbnail(uploadID: "t-" + UUID().uuidString.lowercased(), fileURL: out, mimeType: "image/jpeg", size: UInt64(jpeg.count), sha256: sha)
        #else
        return nil
        #endif
    }
}
