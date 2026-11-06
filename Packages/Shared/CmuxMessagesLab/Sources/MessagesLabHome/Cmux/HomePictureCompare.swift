import AppKit

/// cmux: Before and After in the large picture viewer, one over the other with a slider: left of the divider is
/// the first picture, right of it the second; a drag anywhere (or the Left and Right arrow keys with Option)
/// moves the divider. Both fit the same frame (the first picture's aspect), so a pixel lines up with its pair.
@MainActor
final class HomePictureCompare: NSView {
    var first: CGImage? { didSet { needsDisplay = true } }
    var second: CGImage? { didSet { needsDisplay = true } }
    var firstTitle = "" { didSet { needsDisplay = true } }
    var secondTitle = "" { didSet { needsDisplay = true } }
    /// Where the divider is, 0 (all second) to 1 (all first).
    var split: CGFloat = 0.5 { didSet { split = min(1, max(0, split)); needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// The pictures' frame in `bounds`: the first picture's aspect, as large as fits, centred.
    var pictureFrame: CGRect {
        let image = first ?? second
        guard let image, image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let w = (CGFloat(image.width) * scale).rounded(), h = (CGFloat(image.height) * scale).rounded()
        return CGRect(x: (bounds.midX - w / 2).rounded(), y: (bounds.midY - h / 2).rounded(), width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = pictureFrame
        let x = frame.minX + frame.width * split
        func paint(_ image: CGImage?, clip: CGRect) {
            guard let image else { return }
            ctx.saveGState()
            ctx.clip(to: clip)
            ctx.interpolationQuality = .high
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: frame.size))
            ctx.restoreGState()
        }
        paint(second, clip: CGRect(x: x, y: frame.minY, width: frame.maxX - x, height: frame.height))
        paint(first, clip: CGRect(x: frame.minX, y: frame.minY, width: x - frame.minX, height: frame.height))
        // The divider and its handle.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: x - 1, y: frame.minY, width: 2, height: frame.height))
        let knob = CGRect(x: x - 14, y: frame.midY - 14, width: 28, height: 28)
        ctx.setShadow(offset: .zero, blur: 4, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.fillEllipse(in: knob)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        if let arrows = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            let r = CGRect(x: knob.midX - arrows.size.width / 2, y: knob.midY - arrows.size.height / 2, width: arrows.size.width, height: arrows.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSColor.black.withAlphaComponent(0.7).set()
            arrows.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.75, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        // The names sit on the bottom corners: a window shot keeps its title bar and window buttons on top.
        label(firstTitle, at: CGPoint(x: frame.minX + 10, y: frame.maxY - 10), trailing: false)
        label(secondTitle, at: CGPoint(x: frame.maxX - 10, y: frame.maxY - 10), trailing: true)
    }

    /// A name pill whose bottom edge is at `p.y`, starting (or, `trailing`, ending) at `p.x`.
    private func label(_ text: String, at p: CGPoint, trailing: Bool) {
        guard !text.isEmpty else { return }
        let s = NSAttributedString(string: text, attributes: [.font: HomeFonts.system(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
        let size = s.size()
        let pill = CGRect(x: trailing ? p.x - size.width - 16 : p.x, y: p.y - size.height - 8, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        s.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 4))
    }

    override func mouseDown(with event: NSEvent) { follow(event) }
    override func mouseDragged(with event: NSEvent) { follow(event) }
    override func resetCursorRects() { addCursorRect(pictureFrame, cursor: .resizeLeftRight) }

    private func follow(_ event: NSEvent) {
        let frame = pictureFrame
        guard frame.width > 0 else { return }
        split = (convert(event.locationInWindow, from: nil).x - frame.minX) / frame.width
    }
}
