import AppKit
import UniformTypeIdentifiers

/// cmux: what a Home attachment puts on a pasteboard (Copy) or in a drag (the user, 2026-10-21:
/// "right click any image/video etc 'copy' ... drag it out to other apps too"): the file itself,
/// as Finder's Copy does, so Finder, Messages, Mail and Slack paste the real file; and for an
/// image its own bytes under its type plus TIFF, so Preview's New from Clipboard and apps that
/// read only image data paste the picture rather than a file icon.
struct HomeAttachmentPasteboard {
    /// An image file's bytes (mapped, not copied); nil for another type or a failed read.
    static func imageBytes(_ file: URL) -> Data? {
        guard UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    /// The pasteboard item for `file`: its file URL, its name, and an image's `data`
    /// (``imageBytes(_:)``; read here when not given).
    func item(for file: URL, data given: Data?? = nil) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.lastPathComponent, forType: .string)
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let data = given ?? Self.imageBytes(file) else { return item }
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        if type != .tiff, let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        return item
    }

    /// Replaces the general pasteboard's contents with `item` (Copy); false when it took nothing.
    @MainActor @discardableResult
    static func writeGeneral(_ item: NSPasteboardItem) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
}
