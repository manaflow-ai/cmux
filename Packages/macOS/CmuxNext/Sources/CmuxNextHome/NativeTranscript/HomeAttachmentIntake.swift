import AppKit
import CmuxHomeCore
import ImageIO

/// What the intake reads from a pasteboard: `NSPasteboard` (drop and
/// paste), or a value in tests (a ci-step mini has no pasteboard server).
protocol HomePasteboardContents {
    /// File URLs on the pasteboard, in order (empty when none).
    var fileURLs: [URL] { get }
    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: HomePasteboardContents {
    var fileURLs: [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool { availableType(from: types) != nil }
}

/// What a pasteboard (drop or paste) offers as attachments: file URLs
/// first; else image bytes, but only when there is no text (rich text
/// often carries a picture of itself).
enum HomeAttachmentIntake {
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
    private static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "public.png"), (NSPasteboard.PasteboardType("public.jpeg"), "public.jpeg"), (.tiff, "public.tiff"),
    ]

    /// Whether the pasteboard may hold attachments (types only, no bytes read).
    static func offers(_ board: any HomePasteboardContents) -> Bool {
        if board.hasType([.fileURL]) { return true }
        return !board.hasType([.string]) && board.hasType(imageTypes.map(\.0))
    }

    static func inputs(from board: any HomePasteboardContents) -> [HomeDraftInput] {
        let urls = board.fileURLs
        if !urls.isEmpty { return urls.map { .file($0) } }
        guard !board.hasType([.string]) else { return [] }
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
