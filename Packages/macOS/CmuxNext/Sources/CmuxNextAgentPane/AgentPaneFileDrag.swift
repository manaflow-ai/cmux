import AppKit
import CmuxNextCompat
import UniformTypeIdentifiers

/// The host's drag of a real file out of an agent chat (``AgentPaneReplyLinks/startDrag``): the
/// file URL (and an image's bytes), so Finder, the Desktop and other apps get the file itself.
/// A copy everywhere; the drag starts at once with the file's icon, and an image's picture replaces
/// it when the off-main read ends.
@MainActor
final class AgentPaneFileDrag: NSObject, NSDraggingSource {
    /// What a drag of a file carries besides its URL, read off the main actor (``contents(of:)``):
    /// an image's bytes for the pasteboard and its picture (at most 160 pt) for the drag image;
    /// both nil for another file.
    nonisolated struct Contents {
        var data: Data?
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
    @discardableResult
    func start(_ file: URL, from view: NSView) -> Bool {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: window.mouseLocationOutsideOfEventStream,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
        let pasteboard = AgentPaneFileDragPasteboard(file: file)
        let image = Self.icon(file)
        let item = NSDraggingItem(pasteboardWriter: pasteboard.item())
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        guard !pasteboard.imageTypes.isEmpty else { return true }
        // task-owner: the drag's image read; it ends with the read, and a drag that ended meanwhile ignores its result
        Task { [weak view] in
            let contents = await Self.contents(of: file)
            pasteboard.bytes = pasteboard.bytes ?? contents.data
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
    /// read of the local copy) and its picture, scaled to at most 160 pt.
    @concurrent nonisolated static func contents(of file: URL) async -> sending Contents {
        guard UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true,
              let data = try? Data(blockingContentsOf: file, options: .mappedIfSafe) else { return Contents() }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return Contents(data: data) }
        let scale = 160 / max(image.size.width, image.size.height, 160)
        image.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return Contents(data: data, picture: image)
    }

    /// The file's icon, for a file with no picture.
    private static func icon(_ file: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: file.path)
        icon.size = CGSize(width: 64, height: 64)
        return icon
    }
}
