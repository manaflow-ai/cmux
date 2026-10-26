import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import ImageIO
import UniformTypeIdentifiers

/// The host's drag of a real file out of an agent chat (``AgentPaneReplyLinks/startDrag``): the
/// file URL (and an image's bytes), so Finder, the Desktop and other apps get the file itself.
/// A copy everywhere; the drag starts at once with the file's icon, and an image's picture replaces
/// it when the off-main read ends.
@MainActor
final class AgentPaneFileDrag: NSObject, NSDraggingSource {

    /// What a drag of a file carries besides its URL, read off the main actor (``contents(of:)``):
    /// an image's bytes and TIFF for the pasteboard and its decoded picture (at most 160 pt) for the
    /// drag image; both nil for another file.
    nonisolated struct Contents {
        var image: AgentPanePasteboardImage?
        var picture: NSImage?
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Starts the drag of `file` from `view` at the pointer, while the button is held, in this turn: the
    /// file URL now, the file's icon as the drag image; false without a window. The page cancelled its
    /// own drag, so the drag starts from a fresh dragged event at the pointer. An image's bytes and
    /// picture are read off the main actor after the start (``contents(of:)``): the bytes serve the
    /// pasteboard's image types (``AgentPaneFileDragPasteboard``), and the picture replaces the icon in
    /// the running drag.
    ///
    /// `queries` are the app's Launch Services answers: the file's icon is the kept one, else it replaces a placeholder
    /// when it lands from the system lane.
    @discardableResult
    func start(_ file: URL, from view: NSView, queries: WorkspaceQueries?) -> Bool {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: window.mouseLocationOutsideOfEventStream,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
        let pasteboard = AgentPaneFileDragPasteboard(file: file)
        let iconQuery = WorkspaceQuery<NSImage>.fileIcon(atPath: file.path, side: 64)
        let kept = queries?.cached(iconQuery)
        let image = kept ?? Self.placeholder
        let item = NSDraggingItem(pasteboardWriter: pasteboard.item())
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        guard !pasteboard.imageTypes.isEmpty else {
            // The file's icon replaces the placeholder in the running drag when it lands from the system lane.
            if kept == nil {
                queries?.value(iconQuery, priority: .userBlocking) { [weak view] icon in
                    guard let view else { return }
                    Self.show(icon, in: session, from: view)
                }
            }
            return true
        }
        // task-owner: the drag's image read; it ends with the read, and a drag that ended meanwhile ignores its result
        Task { [weak view] in
            let contents = await Self.contents(of: file)
            pasteboard.image = pasteboard.image ?? contents.image
            guard let picture = contents.picture, let view else { return }
            Self.show(picture, in: session, from: view)
        }
        return true
    }

    /// Replaces the running drag's image with `picture`, centered where the icon was.
    private static func show(_ picture: NSImage, in session: NSDraggingSession, from view: NSView) {
        session.enumerateDraggingItems(options: [], for: view, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            let frame = item.draggingFrame
            item.setDraggingFrame(CGRect(x: frame.midX - picture.size.width / 2, y: frame.midY - picture.size.height / 2,
                                         width: picture.size.width, height: picture.size.height), contents: picture)
        }
    }

    /// Reads what a drag of `file` carries, off the main actor: for an image, its bytes (a mapped
    /// read of the local copy), their TIFF, and its picture, decoded here and scaled to at most 160 pt
    /// (``pictureSide`` pixels, so a Retina drag image is sharp), so drawing the drag image decodes nothing.
    @concurrent nonisolated static func contents(of file: URL) async -> sending Contents {
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let data = try? Data(blockingContentsOf: file, options: .mappedIfSafe) else { return Contents() }
        return Contents(image: AgentPanePasteboardImage(data, type: type), picture: picture(of: data))
    }

    /// The longest side, in pixels, of a drag's decoded picture: 160 pt at 2x.
    nonisolated static let pictureSide = 320

    /// `data`'s picture for the drag image: at most 160 pt on its longest side, from a thumbnail of at most
    /// ``pictureSide`` pixels; nil when it is no image ImageIO reads.
    nonisolated static func picture(of data: Data) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pictureSide, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CheckedImageSource(data), let properties = source.properties(),
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, let thumbnail = source.thumbnail(options: options) else { return nil }
        let scale = 160 / max(CGFloat(width), CGFloat(height), 160)
        return NSImage(cgImage: thumbnail, size: CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale))
    }

    /// The drag image until the file's icon or picture lands: the document symbol, 64 pt.
    private static var placeholder: NSImage {
        let symbol = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
        symbol.size = CGSize(width: 64, height: 64)
        return symbol
    }
}
