#if !canImport(ImageIO)
import Foundation

/// The media readers of ``AttachmentMedia`` where ImageIO and AVFoundation
/// do not exist (Linux): no media facts, previews, posters, thumbnails or
/// conversion. An image, a video or an M4A whose location cannot be checked
/// is refused with `locationNotRemoved` unless the caller keeps location, so
/// no build sends a location it could not look for.
extension AttachmentMedia {
    static var readableImageTypeIdentifiers: [String] { [] }

    static func imageDisplaySize(_ url: URL) -> (width: Int, height: Int)? { nil }

    static func previewJPEG(of url: URL, mimeType: String, byteCount: Int, displaySize: (width: Int, height: Int)) -> Data? {
        nil
    }

    static func thumbnailJPEG(of url: URL, maxPixel: Int, quality: Double = 0.85) throws -> Data {
        throw HomeRejection.invalid("no_thumbnail")
    }

    static func thumbnail(of url: URL, maxPixel: Int) throws -> (data: Data, fileExtension: String) {
        throw HomeRejection.invalid("no_thumbnail")
    }

    static func convertedImage(fileURL: URL) throws -> (data: Data, type: UTType, fileExtension: String)? { nil }

    static func convertedImage(data: Data) throws -> (data: Data, type: UTType, fileExtension: String)? { nil }

    static func inspectMovie(_ url: URL, posterMaxPixel: Int = 1280) async throws -> Movie { Movie() }

    static func imageWithoutLocation(fileURL: URL, mimeType mime: String, name: String) throws -> (data: Data, type: UTType)? {
        guard mime.hasPrefix("image/") else { return nil }
        throw HomeAttachmentError.locationNotRemoved(name: name)
    }

    static func imageWithoutLocation(data: Data, mimeType mime: String, name: String) throws -> (data: Data, type: UTType)? {
        guard mime.hasPrefix("image/") else { return nil }
        throw HomeAttachmentError.locationNotRemoved(name: name)
    }

    static func movieWithoutLocation(_ url: URL, mimeType: String, name: String, root: URL) async throws -> URL? {
        throw HomeAttachmentError.locationNotRemoved(name: name)
    }

    static func linkPreviewJPEG(of url: URL) -> (data: Data, width: Int, height: Int)? { nil }
}
#endif
