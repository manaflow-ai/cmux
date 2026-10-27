import AppKit
import CmuxNextCompatAppKit
import ImageIO
import UniformTypeIdentifiers

/// The host's drag of a real file out of an agent chat (``AgentPaneReplyLinks/startDrag``): the
/// file URL (and an image's bytes), so Finder, the Desktop and other apps get the file itself.
/// A copy everywhere; the drag starts at once with a generic document image, and the file's icon (or an
/// image's picture) replaces it when the lane read ends.
@MainActor
final class AgentPaneFileDrag: NSObject, NSDraggingSource {
    /// What a drag of a file carries besides its URL, read on a blocking-work lane (``contents(of:)``):
    /// an image's bytes and TIFF for the pasteboard and its decoded picture (at most 160 pt), else the
    /// file's icon (``iconSize``), for the drag image. All nil when the reads failed or were cancelled.
    nonisolated struct Contents: Sendable {
        var image: AgentPanePasteboardImage?
        var picture: NSImage?
        var icon: NSImage?
    }

    /// The file's icon at ``iconSize``: a Launch Services query, so a lane body (``launchServicesIcon``).
    typealias IconSource = @Sendable (URL) -> NSImage

    /// The size of the drag image before the lane read ends, and of the file's icon.
    nonisolated static let iconSize = CGSize(width: 64, height: 64)

    /// The app's blocking-work lanes (`AppServices.work`, through ``AgentPaneView``).
    nonisolated let work: any MayBlockRunner
    /// Where the file's icon comes from, on the system lane only; tests pass one that records its calls.
    nonisolated let icon: IconSource

    init(work: any MayBlockRunner, icon: @escaping IconSource = AgentPaneFileDrag.launchServicesIcon) {
        self.work = work
        self.icon = icon
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// Starts the drag of `file` from `view` at the pointer, while the button is held, in this turn: the
    /// item of ``firstItem(_:at:in:)``; false without a window. The page cancelled its own drag, so the drag
    /// starts from a fresh dragged event at the pointer. The file's icon, and an image's bytes and picture, are
    /// read on the lanes after the start (``contents(of:)``). The bytes serve the pasteboard's image types
    /// (``AgentPaneFileDragPasteboard``); the picture or the icon replaces the image of the running drag.
    @discardableResult
    func start(_ file: URL, from view: NSView) -> Bool {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: window.mouseLocationOutsideOfEventStream,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let (item, pasteboard) = firstItem(file, at: point, in: view)
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        // task-owner: the drag's lane reads; it ends with them, and a drag that ended meanwhile ignores the result
        // main-hop-allow: the person's drag, userBlocking (p06 rule 2): contents(of:) reads on the files and system
        // lanes, off main; its one resume sets the image of the running NSDraggingSession, which is main-only and not
        // Sendable, so no posted task can take it
        Task { [weak view] in
            let contents = await self.contents(of: file)
            pasteboard.image = pasteboard.image ?? contents.image
            guard let shown = contents.picture ?? contents.icon, let view else { return }
            Self.show(shown, in: session, from: view)
        }
        return true
    }

    /// The drag's item of the event's turn: the file URL now (``AgentPaneFileDragPasteboard``) and the generic
    /// document image of ``placeholder(appearance:scale:)``, centered at `point`, with no disk read and no
    /// Launch Services query (``icon`` is asked only by ``contents(of:)``).
    func firstItem(_ file: URL, at point: CGPoint, in view: NSView) -> (NSDraggingItem, AgentPaneFileDragPasteboard) {
        let pasteboard = AgentPaneFileDragPasteboard(file: file)
        let image = Self.placeholder(appearance: view.effectiveAppearance, scale: view.window?.backingScaleFactor ?? 2)
        let item = NSDraggingItem(pasteboardWriter: pasteboard.item())
        item.setDraggingFrame(CGRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        return (item, pasteboard)
    }

    /// The SF Symbol `doc` at its own aspect ratio, centered in ``iconSize``, drawn in the label color of
    /// `appearance` into a bitmap of `scale` pixels per point. Drag images are not tinted, so a template
    /// symbol would draw black; this one is not a template and shows in light and dark mode. It asks neither
    /// the disk nor Launch Services.
    static func placeholder(appearance: NSAppearance, scale: CGFloat) -> NSImage {
        let width = Int((iconSize.width * scale).rounded()), height = Int((iconSize.height * scale).rounded())
        let configuration = NSImage.SymbolConfiguration(pointSize: iconSize.height * 0.6, weight: .regular)
        var ink: CGColor?
        appearance.performAsCurrentDrawingAppearance { ink = NSColor.labelColor.cgColor }
        guard let symbol = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?.withSymbolConfiguration(configuration),
              symbol.size.width > 0, symbol.size.height > 0, let ink, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: iconSize) }
        context.scaleBy(x: scale, y: scale)
        // Its own size, scaled down (never up, never on one axis) only if it would not fit.
        let fit = min(1, iconSize.width / symbol.size.width, iconSize.height / symbol.size.height)
        let size = CGSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        let frame = CGRect(x: (iconSize.width - size.width) / 2, y: (iconSize.height - size.height) / 2,
                           width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        // The symbol's coverage, filled with the ink.
        context.setBlendMode(.sourceIn)
        context.setFillColor(ink)
        context.fill(CGRect(origin: .zero, size: iconSize))
        guard let bitmap = context.makeImage() else { return NSImage(size: iconSize) }
        let image = NSImage(cgImage: bitmap, size: iconSize)
        image.isTemplate = false
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

    /// Reads what a drag of `file` carries on ``work``'s lanes, never on the caller's thread: for an image, its
    /// bytes (a mapped read of the local copy), their TIFF, and its picture, decoded and scaled to at most 160 pt
    /// (``pictureSide`` pixels, so a Retina drag image is sharp), on the files lane, so drawing the drag image
    /// decodes nothing; for another file, or an image that does not decode, its ``icon`` on the system lane
    /// (Launch Services). A person holds the drag, so both run at userBlocking.
    nonisolated func contents(of file: URL) async -> Contents {
        var contents = Contents()
        if UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true {
            contents = (try? await work.runFiles(.userBlocking) { Self.image(file) }) ?? Contents()
            if contents.picture != nil { return contents }
        }
        let source = self.icon
        contents.icon = try? await work.runSystem(.userBlocking) { source(file) }
        return contents
    }

    /// An image file's bytes, their TIFF and its decoded picture (a lane body: it reads the disk and decodes).
    private nonisolated static func image(_ file: URL) -> Contents {
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

    /// The file's icon from Launch Services at ``iconSize`` (a lane body).
    nonisolated static let launchServicesIcon: IconSource = { file in
        let icon = NSWorkspace.shared.blockingIcon(forFile: file.path)
        icon.size = AgentPaneFileDrag.iconSize
        return icon
    }
}
