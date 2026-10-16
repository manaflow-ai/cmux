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
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]) {
            mime = "image/png"
        } else if data.starts(with: [0xff, 0xd8, 0xff]) {
            mime = "image/jpeg"
        } else if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            mime = "image/gif"
        } else if data.starts(with: Data("RIFF".utf8)), data.count >= 12,
                  data.subdata(in: 8..<12) == Data("WEBP".utf8) {
            mime = "image/webp"
        } else {
            throw CloudImagePasteError.unsupportedType
        }
        self.data = data
    }
}
