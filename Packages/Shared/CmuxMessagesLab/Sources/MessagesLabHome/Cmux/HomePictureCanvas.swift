import AppKit

/// cmux: the picture in the large picture viewer (``HomePictureViewer``), as large as its points (a 2x screenshot
/// at half its pixels) inside the viewer's zooming scroll view, with its marks (``HomePictureMarkup``) drawn over
/// it. The drawing tools make marks with the pointer; Move drags the picture around when it is zoomed in.
@MainActor
final class HomePictureCanvas: NSView {
    enum Tool: Int, CaseIterable, Sendable {
        case move, arrow, box, pen, text
    }

    var image: CGImage? { didSet { needsDisplay = true } }
    var markup = HomePictureMarkup() { didSet { needsDisplay = true } }
    var tool: Tool = .move { didSet { window?.invalidateCursorRects(for: self) } }
    /// A mark was finished with the pointer.
    var onMark: (HomePictureMarkup.Mark) -> Void = { _ in }
    /// A click with the Text tool: where the words go (picture pixels) and the click in this view.
    var onTextAt: (CGPoint, CGPoint) -> Void = { _, _ in }
    /// A double-click with Move: zoom to the picture's own size or back to fit.
    var onToggleZoom: () -> Void = {}

    private var drawing: HomePictureMarkup.Mark?
    private var start: CGPoint = .zero
    private var panFrom: (point: CGPoint, origin: CGPoint)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// The picture's size in pixels (zero without a picture).
    var pixelSize: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    /// The view point `p` in picture pixels.
    func pixels(_ p: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let size = pixelSize
        return CGPoint(x: min(max(0, p.x), bounds.width) * size.width / bounds.width,
                       y: min(max(0, p.y), bounds.height) * size.height / bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
        let size = pixelSize
        guard size.width > 0, size.height > 0 else { return }
        ctx.saveGState()
        ctx.scaleBy(x: bounds.width / size.width, y: bounds.height / size.height)
        markup.draw(in: ctx, pictureSize: size)
        if let drawing { HomePictureMarkup.draw(drawing, in: ctx, pictureSize: size) }
        ctx.restoreGState()
    }

    override func resetCursorRects() {
        switch tool {
        case .move: addCursorRect(bounds, cursor: .openHand)
        case .text: addCursorRect(bounds, cursor: .iBeam)
        case .arrow, .box, .pen: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        start = pixels(p)
        switch tool {
        case .move:
            if event.clickCount == 2 { onToggleZoom(); return }
            if let clip = enclosingScrollView?.contentView {
                panFrom = (event.locationInWindow, clip.bounds.origin)
                NSCursor.closedHand.push()
            }
        case .text: onTextAt(start, p)
        case .arrow: drawing = .arrow(from: start, to: start)
        case .box: drawing = .box(CGRect(origin: start, size: .zero))
        case .pen: drawing = .pen([start])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let panFrom, let scroll = enclosingScrollView {
            let clip = scroll.contentView
            let m = max(0.01, scroll.magnification)
            let d = CGPoint(x: event.locationInWindow.x - panFrom.point.x, y: event.locationInWindow.y - panFrom.point.y)
            // The clip view is flipped like this canvas: a drag down shows what is above.
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: CGPoint(x: panFrom.origin.x - d.x / m, y: panFrom.origin.y + d.y / m),
                                                            size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            return
        }
        let p = pixels(convert(event.locationInWindow, from: nil))
        switch drawing {
        case .arrow: drawing = .arrow(from: start, to: p)
        case .box: drawing = .box(CGRect(x: start.x, y: start.y, width: p.x - start.x, height: p.y - start.y).standardized)
        case .pen(let points): drawing = .pen(points + [p])
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if panFrom != nil {
            panFrom = nil
            NSCursor.pop()
            return
        }
        guard let mark = drawing else { return }
        drawing = nil
        needsDisplay = true
        switch mark {
        case let .arrow(from, to) where hypot(to.x - from.x, to.y - from.y) < 4: return
        case let .box(rect) where rect.width < 3 || rect.height < 3: return
        default: onMark(mark)
        }
    }
}
