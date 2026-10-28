import AppKit

/// Supplies a picture's bytes to a pasteboard only when a receiver asks for
/// them (an app that takes image data, not the file). A drop into Finder, a
/// terminal or a chat composer reads the file URL and never reads the file.
nonisolated final class FileGridImageDataProvider: NSObject, NSPasteboardItemDataProvider {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        item.setData(data, forType: type)
    }
}
