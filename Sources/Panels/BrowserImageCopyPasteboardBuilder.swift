import AppKit
import UniformTypeIdentifiers

enum BrowserImageCopyPasteboardBuilder {
    private static let pngPasteboardType = NSPasteboard.PasteboardType(UTType.png.identifier)
    private static let tiffPasteboardType = NSPasteboard.PasteboardType(UTType.tiff.identifier)
    private static let urlPasteboardType = NSPasteboard.PasteboardType(UTType.url.identifier)

    static func makePasteboardItems(from payload: BrowserImageCopyPasteboardPayload) -> [NSPasteboardItem] {
        guard let imageItem = imagePasteboardItem(from: payload) else { return [] }

        var items = [imageItem]
        if let sourceURL = payload.sourceURL {
            // Keep the URL as a secondary item so image-aware paste targets can
            // prefer the binary image payload without losing the textual fallback.
            items.append(urlPasteboardItem(for: sourceURL))
        }
        return items
    }

    private static func imagePasteboardItem(from payload: BrowserImageCopyPasteboardPayload) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        var wroteImageType = false

        if let image = NSImage(data: payload.imageData) {
            if let tiffData = image.tiffRepresentation, !tiffData.isEmpty {
                item.setData(tiffData, forType: tiffPasteboardType)
                wroteImageType = true
            }
            if let pngData = pngData(for: image), !pngData.isEmpty {
                item.setData(pngData, forType: pngPasteboardType)
                wroteImageType = true
            }
        }

        if let sourceType = sourceImageType(mimeType: payload.mimeType, sourceURL: payload.sourceURL) {
            item.setData(payload.imageData, forType: NSPasteboard.PasteboardType(sourceType.identifier))
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

    private static func sourceImageType(mimeType: String?, sourceURL: URL?) -> UTType? {
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
