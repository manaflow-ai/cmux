import AppKit
import UniformTypeIdentifiers

/// What a drag of a file out of an agent chat puts on the drag pasteboard (``AgentPaneFileDrag``): the file
/// URL and its name at once, and for an image its bytes (and a TIFF) through a data provider, so the drag
/// starts in the event's turn with no read.
///
/// The bytes come from the drag's off-main read (``AgentPaneFileDrag/contents(of:)``) once it ends
/// (``bytes``). A drop target that asks for an image type before that read ends gets no data for it (the
/// main thread never reads the file); it still has the file URL, which Finder and most apps take.
@MainActor
final class AgentPaneFileDragPasteboard: NSObject, NSPasteboardItemDataProvider {
    let file: URL
    /// The image's bytes, from the off-main read; nil until it ends (or for another file).
    var bytes: Data?
    /// The image types the provider answers for (the file's own type and TIFF); empty for another file.
    let imageTypes: [NSPasteboard.PasteboardType]
    init(file: URL) {
        self.file = file
        if let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) {
            let own = NSPasteboard.PasteboardType(type.identifier)
            imageTypes = type == .tiff ? [own] : [own, .tiff]
        } else {
            imageTypes = []
        }
    }

    /// The drag's pasteboard item: URL and name now, image types on request.
    func item() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.lastPathComponent, forType: .string)
        if !imageTypes.isEmpty { item.setDataProvider(self, forTypes: imageTypes) }
        return item
    }

    /// The bytes for `type` from ``bytes``; nil before the off-main read ended (no read here).
    func data(for type: NSPasteboard.PasteboardType) -> Data? {
        guard imageTypes.contains(type), let data = bytes else { return nil }
        if type == .tiff, imageTypes.first != .tiff { return NSImage(data: data)?.tiffRepresentation }
        return data
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // main-proof: AppKit asks a drag's data provider on the main thread (the drop's turn)
        MainActor.assumeIsolated {
            if let data = data(for: type) { item.setData(data, forType: type) }
        }
    }
}
