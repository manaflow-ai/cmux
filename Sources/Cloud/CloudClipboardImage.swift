import Foundation

/// A bounded image read from the existing clipboard materialization seam.
struct CloudClipboardImage: Sendable {
    static let maximumBytes = 20 * 1024 * 1024
    let data: Data
    let mime: String

    init(data: Data) throws {
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
