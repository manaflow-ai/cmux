import Foundation
import UniformTypeIdentifiers

/// Encodes user-picked local files into the agent chat bridge's file-attachment
/// wire dictionaries, inlining small images as base64 `data:` URL previews.
///
/// The composer's "Add photos & files" panel hands the picked URLs to
/// ``encode(_:)``, which produces one `[String: Any]` per file with `label`,
/// `path`, `fsPath`, `mimeType`, and `isImage`. Image files within the
/// per-file and cumulative byte caps also gain a `dataUrl` preview; the running
/// budget is threaded across the batch so one panel selection cannot inline
/// more than ``totalPreviewByteLimit`` of image data.
public struct LocalAttachmentEncoder: Sendable {
    /// Largest single image, in bytes, eligible for an inline preview.
    public let perFilePreviewByteLimit: Int

    /// Largest cumulative inline-preview payload, in bytes, across one batch.
    public let totalPreviewByteLimit: Int

    /// Creates an encoder.
    ///
    /// - Parameters:
    ///   - perFilePreviewByteLimit: Largest single image eligible for an inline
    ///     preview. Defaults to 512 KiB.
    ///   - totalPreviewByteLimit: Largest cumulative inline-preview payload
    ///     across one batch. Defaults to 2 MiB.
    public init(
        perFilePreviewByteLimit: Int = 512 * 1024,
        totalPreviewByteLimit: Int = 2 * 1024 * 1024
    ) {
        self.perFilePreviewByteLimit = perFilePreviewByteLimit
        self.totalPreviewByteLimit = totalPreviewByteLimit
    }

    /// Encodes picked file URLs into bridge file-attachment dictionaries.
    ///
    /// - Parameter urls: The user-picked file URLs, in selection order.
    /// - Returns: One dictionary per URL. Eligible images additionally carry a
    ///   base64 `dataUrl` preview, gated by the encoder's byte limits.
    public func encode(_ urls: [URL]) -> [[String: Any]] {
        var remainingPreviewBytes = totalPreviewByteLimit
        return urls.map { fileDictionary($0, remainingPreviewBytes: &remainingPreviewBytes) }
    }

    private func fileDictionary(
        _ url: URL,
        remainingPreviewBytes: inout Int
    ) -> [String: Any] {
        let type = UTType(filenameExtension: url.pathExtension)
        let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
        let isImage = type?.conforms(to: .image) == true
        var file: [String: Any] = [
            "label": url.lastPathComponent,
            "path": url.path,
            "fsPath": url.path,
            "mimeType": mimeType,
            "isImage": isImage
        ]
        if isImage,
           let byteCount = Self.previewByteCount(url),
           byteCount <= perFilePreviewByteLimit,
           byteCount <= remainingPreviewBytes,
           let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           data.count <= byteCount {
            remainingPreviewBytes -= data.count
            file["dataUrl"] = "data:\(mimeType);base64,\(data.base64EncodedString())"
        }
        return file
    }

    private static func previewByteCount(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType != .typeSymbolicLink,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        let byteCount = size.intValue
        return byteCount >= 0 ? byteCount : nil
    }
}
