public import AppKit
import UniformTypeIdentifiers

/// What a grid puts on a pasteboard for its files, for both drag and Copy:
/// each file's URL (Finder, terminals, chat composers and browsers take it
/// as the file) and, for one picture, its bytes under its own type, so an
/// app that takes only image data (a canvas, an image field) gets the
/// picture too. The bytes are read only if a receiver asks for them.
@MainActor
public final class FileGridPasteboard {
    /// The largest picture whose bytes are offered with its URL.
    public let maxImageBytes: Int64
    /// The providers of offered bytes; the newest few stay alive for the receiver to ask.
    private var providers: [FileGridImageDataProvider] = []

    /// Makes the writer.
    ///
    /// - Parameter maxImageBytes: bytes above which only the URL is written (default 64 MB).
    public init(maxImageBytes: Int64 = 64 << 20) {
        self.maxImageBytes = maxImageBytes
    }

    /// One pasteboard item for `item`.
    ///
    /// - Parameters:
    ///   - item: the file.
    ///   - includeImageData: also offer a picture's bytes (one dragged or copied picture).
    /// - Returns: the item to write or drag.
    public func pasteboardItem(for item: FileGridItem, includeImageData: Bool) -> NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)
        guard includeImageData, item.kind == .image, item.size <= maxImageBytes,
              let type = UTType(filenameExtension: item.url.pathExtension.lowercased()), type.conforms(to: .image) else {
            return pasteboardItem
        }
        let provider = FileGridImageDataProvider(url: item.url)
        providers.append(provider)
        if providers.count > 8 { providers.removeFirst(providers.count - 8) }
        pasteboardItem.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType(type.identifier)])
        return pasteboardItem
    }

    /// Replaces `pasteboard`'s contents with `items` (Copy).
    ///
    /// - Parameters:
    ///   - items: the files, in order.
    ///   - pasteboard: the pasteboard.
    public func write(_ items: [FileGridItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(pasteboardItems(for: items))
    }

    /// The pasteboard items for a Copy or a drag of `items`: one per file, with a lone
    /// picture's bytes.
    ///
    /// - Parameter items: the files, in order.
    /// - Returns: the items, in order.
    public func pasteboardItems(for items: [FileGridItem]) -> [NSPasteboardItem] {
        let single = items.count == 1
        return items.map { pasteboardItem(for: $0, includeImageData: single) }
    }

    /// The text Copy Path writes: the files' paths, one per line.
    ///
    /// - Parameter items: the files, in order.
    /// - Returns: the paths.
    public func pathsText(for items: [FileGridItem]) -> String {
        items.map(\.url.path).joined(separator: "\n")
    }

    /// Writes the files' paths as text, one per line (Copy Path).
    ///
    /// - Parameters:
    ///   - items: the files.
    ///   - pasteboard: the pasteboard.
    public func writePaths(_ items: [FileGridItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(pathsText(for: items), forType: .string)
    }
}
