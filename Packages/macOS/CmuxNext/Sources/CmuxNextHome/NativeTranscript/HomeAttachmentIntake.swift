import AppKit
import CmuxHomeCore
import ImageIO

/// What a pasteboard (drop or paste) offers as attachments: file URLs
/// first; else image bytes, but only when there is no text (rich text
/// often carries a picture of itself).
enum HomeAttachmentIntake {
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
    private static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "public.png"), (NSPasteboard.PasteboardType("public.jpeg"), "public.jpeg"), (.tiff, "public.tiff"),
    ]

    /// Whether the pasteboard may hold attachments (types only, no bytes read).
    static func offers(_ board: NSPasteboard) -> Bool {
        if board.availableType(from: [.fileURL]) != nil { return true }
        return board.availableType(from: [.string]) == nil && board.availableType(from: imageTypes.map(\.0)) != nil
    }

    static func inputs(from board: NSPasteboard) -> [HomeDraftInput] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.map { .file($0) }
        }
        guard board.availableType(from: [.string]) == nil else { return [] }
        for (type, identifier) in imageTypes {
            guard let data = board.data(forType: type) else { continue }
            // TIFF is not on the allow list: a TIFF-only picture is sent as PNG.
            if identifier == "public.tiff" {
                guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return [] }
                return [.data(png, typeIdentifier: "public.png")]
            }
            return [.data(data, typeIdentifier: identifier)]
        }
        return []
    }
}

/// A draft attachment in the composer tray.
struct HomeDraftAttachment {
    var prepared: LocalAttachment
    /// A small decoded picture for the tray (and the first frame of the send morph).
    var thumbnail: CGImage?

    var ref: AttachmentRef { prepared.ref }

    /// The tray picture: the poster or the image itself, decoded off the main actor.
    static func thumbnail(for prepared: LocalAttachment, maxPixel: Int = 640) async -> CGImage? {
        let type = prepared.ref.mimeType.lowercased()
        let url: URL? = prepared.posterURL ?? (type.hasPrefix("image/") ? prepared.fileURL : nil)
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}
