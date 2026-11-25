import CmuxMobileTransport
import Foundation

#if os(iOS)
import UIKit
/// Starts terminal attachment uploads while the composer is being filled.
///
/// A terminal attachment is always a path typed into the Mac, so it can use the
/// same upload service before Send. Entries are claimed by Send and therefore
/// survive the composer being cleared while the prompt is handed to the PTY.
@MainActor
final class ComposerAttachmentPrestager {
    typealias Upload = @MainActor (LinkUpload.Payload, String) async throws -> String

    struct Entry {
        let task: Task<String, any Error>
        let name: String
        let payload: LinkUpload.Payload
    }

    private(set) var entries: [ComposerAttachment.ID: Entry] = [:]
    private var claimedEntries: [ComposerAttachment.ID: Entry] = [:]

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
            guard let transfer = try? attachment.transferPayload() else { continue }
            if let existing = entries[attachment.id] {
                if existing.name == transfer.name, existing.payload == transfer.payload { continue }
                existing.task.cancel()
                entries[attachment.id] = nil
            }
            let task = Task<String, any Error> { @MainActor in
                try await upload(transfer.payload, transfer.name)
            }
            entries[attachment.id] = Entry(task: task, name: transfer.name, payload: transfer.payload)
        }
    }

    func claim(_ attachments: [ComposerAttachment]) -> [ComposerAttachment.ID: Entry] {
        var claimed: [ComposerAttachment.ID: Entry] = [:]
        for attachment in attachments {
            if let entry = entries.removeValue(forKey: attachment.id) {
                claimed[attachment.id] = entry
                claimedEntries[attachment.id] = entry
            }
        }
        return claimed
    }

    func cancelClaimed() {
        for entry in claimedEntries.values { entry.task.cancel() }
        claimedEntries.removeAll()
    }

    func releaseClaimed() {
        claimedEntries.removeAll()
    }

    func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
        cancelClaimed()
    }

    isolated deinit {
        for entry in entries.values { entry.task.cancel() }
        for entry in claimedEntries.values { entry.task.cancel() }
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
        return TransferPayload(payload: try payload(), name: name)
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
