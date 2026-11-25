#if os(iOS)
import CmuxMobileTransport
import Foundation
import UIKit

/// Starts terminal attachment uploads as soon as the user picks them. A
/// completed path is reused by Send, while a removed attachment cancels its
/// task. The original bytes stay on the attachment for preview and retry.
@MainActor
final class ComposerAttachmentPrestager {
    typealias Upload = @MainActor (LinkUpload.Payload, String) async throws -> String

    struct Entry {
        let signature: Signature
        let task: Task<String, any Error>
    }

    struct Signature: Equatable {
        let name: String
        let byteCount: Int?
        let dataHash: Int?
        let fileURL: String?

        init(_ attachment: ComposerAttachment) {
            name = attachment.name
            byteCount = attachment.byteCount
            dataHash = attachment.data?.hashValue
            fileURL = attachment.fileURL?.absoluteString
        }
    }

    private(set) var entries: [ComposerAttachment.ID: Entry] = [:]

    func sync(_ attachments: [ComposerAttachment], upload: Upload?) {
        let wanted = Set(attachments.map(\.id))
        for (id, entry) in entries where !wanted.contains(id) {
            entry.task.cancel()
            entries[id] = nil
        }
        guard let upload else {
            cancelAll()
            return
        }
        for attachment in attachments {
            let signature = Signature(attachment)
            if let existing = entries[attachment.id], existing.signature == signature { continue }
            if let existing = entries.removeValue(forKey: attachment.id) { existing.task.cancel() }
            let task = Task<String, any Error> {
                let transfer = try attachment.transferPayload()
                return try await upload(transfer.payload, transfer.name)
            }
            entries[attachment.id] = Entry(signature: signature, task: task)
        }
    }

    func claim(_ attachment: ComposerAttachment) -> Entry? {
        entries.removeValue(forKey: attachment.id)
    }

    func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }

    deinit {
        for entry in entries.values { entry.task.cancel() }
    }
}

extension ComposerAttachment {
    struct TransferPayload {
        let payload: LinkUpload.Payload
        let name: String
    }

    func transferPayload() throws -> TransferPayload {
        if kind == .image, let data, let optimized = Self.optimizedImage(data: data, name: name) {
            return TransferPayload(payload: .data(optimized.data), name: optimized.name)
        }
        if let data { return TransferPayload(payload: .data(data), name: name) }
        if let fileURL { return TransferPayload(payload: .file(fileURL), name: name) }
        throw Unreadable()
    }

    private static func optimizedImage(data: Data, name: String) -> (data: Data, name: String)? {
        guard let image = UIImage(data: data), image.images == nil else { return nil }
        let pixelSize: CGSize
        if let cgImage = image.cgImage {
            pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else {
            pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        }
        let longSide = max(pixelSize.width, pixelSize.height)
        let scale = min(1, 2048 / max(longSide, 1))
        let target = CGSize(width: max(1, pixelSize.width * scale), height: max(1, pixelSize.height * scale))
        let hasAlpha: Bool
        if let alpha = image.cgImage?.alphaInfo {
            hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
        } else {
            hasAlpha = false
        }
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { image.draw(in: CGRect(origin: .zero, size: target)) }
        let encoded = hasAlpha ? rendered.pngData() : rendered.jpegData(compressionQuality: 0.85)
        guard let encoded, encoded.count < data.count || longSide > 2048 else { return nil }
        let ext = hasAlpha ? "png" : "jpg"
        let base = (name as NSString).deletingPathExtension
        let outputName = base.isEmpty ? "attachment.\(ext)" : "\(base).\(ext)"
        return (encoded, outputName)
    }
}
#endif
