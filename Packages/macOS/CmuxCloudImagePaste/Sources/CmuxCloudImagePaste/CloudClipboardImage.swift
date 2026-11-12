public import Foundation

/// A bounded, signature-validated image payload ready for Cloud transfer.
public struct CloudClipboardImage: Sendable {
    /// The maximum number of bytes accepted from the clipboard.
    public static let maximumBytes = 20 * 1024 * 1024
    /// The validated image bytes.
    public let data: Data
    /// The MIME type derived from the image signature.
    public let mime: String

    /// Validates an image payload and derives its supported MIME type.
    ///
    /// - Parameter data: The complete clipboard image payload.
    /// - Throws: ``CloudImagePasteError/sizeLimit`` or
    ///   ``CloudImagePasteError/unsupportedType`` when the payload is not
    ///   supported by the Cloud daemon.
    public init(data: Data) throws {
        guard !data.isEmpty else { throw CloudImagePasteError.unsupportedType }
        guard data.count <= Self.maximumBytes else { throw CloudImagePasteError.sizeLimit }
        mime = try Self.mime(forSignature: data)
        self.data = data
    }

    /// Checks an image file's size and signature without reading the payload.
    ///
    /// This is the cheap check a composer runs when an image is attached, so an
    /// unsupported file is refused before it can be submitted. Upload still
    /// reads the file through ``CloudClipboardImageReader``, which repeats both
    /// checks on the bytes it sends.
    ///
    /// - Parameter url: The attached image file.
    /// - Throws: ``CloudImagePasteError/sizeLimit``,
    ///   ``CloudImagePasteError/unsupportedType`` or
    ///   ``CloudImagePasteError/storage`` when the file cannot be sent.
    public static func validateFile(at url: URL) throws {
        guard url.isFileURL else { throw CloudImagePasteError.unsupportedType }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let values else { throw CloudImagePasteError.storage }
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw CloudImagePasteError.unsupportedType
        }
        guard size <= maximumBytes else { throw CloudImagePasteError.sizeLimit }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            header = try handle.read(upToCount: 12) ?? Data()
        } catch {
            throw CloudImagePasteError.storage
        }
        _ = try mime(forSignature: header)
    }

    /// The MIME type for a payload's leading bytes. Only the first 12 bytes
    /// are read.
    private static func mime(forSignature data: Data) throws -> String {
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]) {
            return "image/png"
        } else if data.starts(with: [0xff, 0xd8, 0xff]) {
            return "image/jpeg"
        } else if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return "image/gif"
        } else if data.starts(with: Data("RIFF".utf8)), data.count >= 12,
                  data.subdata(in: data.startIndex + 8..<data.startIndex + 12) == Data("WEBP".utf8) {
            return "image/webp"
        }
        throw CloudImagePasteError.unsupportedType
    }
}
