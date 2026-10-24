import AppKit
import UniformTypeIdentifiers

/// The host's drag of a real file out of an agent chat (``AgentPaneReplyLinks/startDrag``): the
/// file URL (and an image's bytes), so Finder, the Desktop and other apps get the file itself.
/// A copy everywhere; the drag image is the picture or the file's icon.
@MainActor
final class AgentPaneFileDrag: NSObject, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Starts the drag of `file` from `view` at the pointer, while the button is held; false
    /// without a window. The page cancelled its own drag, so the drag starts from a fresh
    /// dragged event at the pointer.
    @discardableResult
    func start(_ file: URL, from view: NSView) -> Bool {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: window.mouseLocationOutsideOfEventStream,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
        let image = Self.preview(file)
        // Reads an image's bytes for the drag; the file is a local copy the drag needs now.
        let data = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
            ? try? Data(contentsOf: file, options: .mappedIfSafe) // concurrency-allow: a drag's data must be on the pasteboard when it starts; a mapped read of a local copy
            : nil
        let item = NSDraggingItem(pasteboardWriter: AgentPaneImageCopies.pasteboardItem(file, data: data))
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        view.beginDraggingSession(with: [item], event: event, source: self)
        return true
    }

    /// The picture (at most 160 pt) for an image, else the file's icon.
    private static func preview(_ file: URL) -> NSImage {
        if UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true,
           let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0 { // concurrency-allow: the drag image, from the same local copy, at drag start
            let scale = 160 / max(image.size.width, image.size.height, 160)
            image.size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return image
        }
        let icon = NSWorkspace.shared.icon(forFile: file.path)
        icon.size = CGSize(width: 64, height: 64)
        return icon
    }
}
