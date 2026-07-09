public import AppKit
public import Foundation
import UniformTypeIdentifiers

/// An image captured from a browser context-menu "Copy Image" action, plus the
/// AppKit pasteboard items it produces. Owns the pure `NSPasteboardItem`
/// construction (TIFF/PNG/source-type image data plus an optional URL fallback)
/// so the webview only has to write the resulting items to the pasteboard.
public struct BrowserImageCopyPasteboardPayload {
    public let imageData: Data
    public let mimeType: String?
    public let sourceURL: URL?

    public init(imageData: Data, mimeType: String?, sourceURL: URL?) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.sourceURL = sourceURL
    }

    private static let pngPasteboardType = NSPasteboard.PasteboardType(UTType.png.identifier)
    private static let tiffPasteboardType = NSPasteboard.PasteboardType(UTType.tiff.identifier)
    private static let urlPasteboardType = NSPasteboard.PasteboardType(UTType.url.identifier)

    /// The pasteboard items representing this image, in preference order: the
    /// binary image item first, then an optional textual URL fallback. Empty when
    /// no image representation could be produced.
    public var pasteboardItems: [NSPasteboardItem] {
        guard let imageItem = imagePasteboardItem() else { return [] }

        var items = [imageItem]
        if let sourceURL {
            // Keep the URL as a secondary item so image-aware paste targets can
            // prefer the binary image payload without losing the textual fallback.
            items.append(Self.urlPasteboardItem(for: sourceURL))
        }
        return items
    }

    private func imagePasteboardItem() -> NSPasteboardItem? {
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

        if let sourceType = sourceImageType() {
            item.setData(imageData, forType: NSPasteboard.PasteboardType(sourceType.identifier))
            wroteImageType = true
        }

        return wroteImageType ? item : nil
    }

    private static func urlPasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .string)
        item.setString(url.absoluteString, forType: urlPasteboardType)
        return item
    }

    private func sourceImageType() -> UTType? {
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

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
