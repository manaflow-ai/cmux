import AppKit
import CmuxNextCompat
import UniformTypeIdentifiers

/// The host's drag of a real file out of an agent chat (``AgentPaneReplyLinks/startDrag``): the
/// file URL (and an image's bytes), so Finder, the Desktop and other apps get the file itself.
/// A copy everywhere; the drag starts at once with a generic document image, and the file's icon (or an
/// image's picture) replaces it when the lane read ends.
@MainActor
final class AgentPaneFileDrag: NSObject, NSDraggingSource {
    /// What a drag of a file carries besides its URL, read on a blocking-work lane (``contents(of:on:)``):
    /// an image's bytes for the pasteboard and its picture (at most 160 pt), else the file's icon
    /// (``iconSize``), for the drag image. All nil when the reads failed or were cancelled.
    nonisolated struct Contents: Sendable {
        var data: Data?
        var picture: NSImage?
        var icon: NSImage?
    }

    /// The size of the drag image before the lane read ends, and of the file's icon.
    nonisolated static let iconSize = CGSize(width: 64, height: 64)

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Starts the drag of `file` from `view` at the pointer, while the button is held, in this turn: the
    /// file URL now and a generic document image (``placeholder()``); false without a window. The page
    /// cancelled its own drag, so the drag starts from a fresh dragged event at the pointer. The turn asks
    /// neither the disk nor Launch Services: the file's icon, and an image's bytes and picture, are read on
    /// `work`'s lanes after the start (``contents(of:on:)``). The bytes serve the pasteboard's image types
    /// (``AgentPaneFileDragPasteboard``); the picture or the icon replaces the image of the running drag.
    /// With no `work` (a pane the app did not wire) the drag keeps the generic image.
    @discardableResult
    func start(_ file: URL, from view: NSView, work: (any MayBlockRunner)?) -> Bool {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: window.mouseLocationOutsideOfEventStream,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
        let pasteboard = AgentPaneFileDragPasteboard(file: file)
        let image = Self.placeholder()
        let item = NSDraggingItem(pasteboardWriter: pasteboard.item())
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        guard let work else { return true }
        // task-owner: the drag's lane reads; it ends with them, and a drag that ended meanwhile ignores the result
        Task { [weak view] in
            let contents = await Self.contents(of: file, on: work)
            pasteboard.bytes = pasteboard.bytes ?? contents.data
            guard let shown = contents.picture ?? contents.icon, let view else { return }
            Self.show(shown, in: session, from: view)
        }
        return true
    }

    /// The drag image of the event's turn: a generic document symbol, made with no file or Launch Services
    /// query (the file's own icon comes from the lane read).
    static func placeholder() -> NSImage {
        let image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage(size: iconSize)
        image.size = iconSize
        return image
    }

    /// Replaces the running drag's image with `picture`, centered where the first image was.
    private static func show(_ picture: NSImage, in session: NSDraggingSession, from view: NSView) {
        session.enumerateDraggingItems(options: [], for: view, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            let frame = item.draggingFrame
            item.setDraggingFrame(CGRect(x: frame.midX - picture.size.width / 2, y: frame.midY - picture.size.height / 2,
                                         width: picture.size.width, height: picture.size.height), contents: picture)
        }
    }

    /// Reads what a drag of `file` carries on `work`'s lanes, never on the caller's thread: for an image, its
    /// bytes (a mapped read of the local copy) and its picture, scaled to at most 160 pt, on the files lane;
    /// for another file, or an image that does not decode, its icon on the system lane (Launch Services). A
    /// person holds the drag, so both run at userBlocking.
    nonisolated static func contents(of file: URL, on work: any MayBlockRunner) async -> Contents {
        var contents = Contents()
        if UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true {
            contents = (try? await work.runFiles(.userBlocking) { Self.image(file) }) ?? Contents()
            if contents.picture != nil { return contents }
        }
        contents.icon = try? await work.runSystem(.userBlocking) { Self.icon(file) }
        return contents
    }

    /// An image file's bytes and its picture, scaled to at most 160 pt (a lane body: it reads the disk).
    private nonisolated static func image(_ file: URL) -> Contents {
        guard let data = try? Data(blockingContentsOf: file, options: .mappedIfSafe) else { return Contents() }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return Contents(data: data) }
        let scale = 160 / max(image.size.width, image.size.height, 160)
        image.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return Contents(data: data, picture: image)
    }

    /// The file's icon at ``iconSize`` (a lane body: it asks Launch Services).
    private nonisolated static func icon(_ file: URL) -> NSImage {
        let icon = NSWorkspace.shared.blockingIcon(forFile: file.path)
        icon.size = iconSize
        return icon
    }
}
