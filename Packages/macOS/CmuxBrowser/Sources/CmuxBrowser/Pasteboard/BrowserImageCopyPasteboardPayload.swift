public import AppKit
public import Foundation
import UniformTypeIdentifiers

/// The fetched bytes of a browser context-menu "Copy Image", plus the metadata
/// needed to format them onto the system pasteboard.
///
/// Constructed by `CmuxWebView` from a `data:`, `file:`, or `http(s)` image
/// source, then asked for its `pasteboardItems` to write image-aware (and a
/// textual URL fallback) representations onto `NSPasteboard.general`. The payload
/// owns the formatting so there is no separate stateless builder namespace.
public struct BrowserImageCopyPasteboardPayload {
    /// The raw image bytes as fetched from the source.
    public let imageData: Data
    /// The source MIME type when known (response header or data-URL declaration).
    public let mimeType: String?
    /// The resolved http(s) image URL kept as a textual fallback item, or nil
    /// for `data:`/`file:` sources that have no shareable URL.
    public let sourceURL: URL?

    /// Creates a payload from fetched image bytes and their source metadata.
    public init(imageData: Data, mimeType: String?, sourceURL: URL?) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.sourceURL = sourceURL
    }

    private static let pngPasteboardType = NSPasteboard.PasteboardType(UTType.png.identifier)
    private static let tiffPasteboardType = NSPasteboard.PasteboardType(UTType.tiff.identifier)
    private static let urlPasteboardType = NSPasteboard.PasteboardType(UTType.url.identifier)

    /// The pasteboard items to write for this image copy: an image item carrying
    /// every representation that could be produced (TIFF, PNG, and the original
    /// source type), plus a secondary URL item when a `sourceURL` exists.
    ///
    /// Empty when no image representation could be produced, so callers can fall
    /// back without writing a partial payload.
    public var pasteboardItems: [NSPasteboardItem] {
        guard let imageItem else { return [] }

        var items = [imageItem]
        if let sourceURL {
            // Keep the URL as a secondary item so image-aware paste targets can
            // prefer the binary image payload without losing the textual fallback.
            items.append(Self.urlPasteboardItem(for: sourceURL))
        }
        return items
    }

    private var imageItem: NSPasteboardItem? {
        let item = NSPasteboardItem()
        var wroteImageType = false

        if let image = NSImage(data: imageData) {
            if let tiffData = image.tiffRepresentation, !tiffData.isEmpty {
                item.setData(tiffData, forType: Self.tiffPasteboardType)
                wroteImageType = true
            }
            if let pngData = Self.pngData(for: image), !pngData.isEmpty {
                item.setData(pngData, forType: Self.pngPasteboardType)
                wroteImageType = true
            }
        }

        if let sourceType {
            item.setData(imageData, forType: NSPasteboard.PasteboardType(sourceType.identifier))
            wroteImageType = true
        }

        return wroteImageType ? item : nil
    }

    private var sourceType: UTType? {
        if let mimeType,
           let type = UTType(mimeType: mimeType),
           type.conforms(to: .image) {
            return type
        }

        if let pathExtension = sourceURL?.pathExtension,
           !pathExtension.isEmpty,
           let type = UTType(filenameExtension: pathExtension),
           type.conforms(to: .image) {
            return type
        }

        return nil
    }

    private static func urlPasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .string)
        item.setString(url.absoluteString, forType: urlPasteboardType)
        return item
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
