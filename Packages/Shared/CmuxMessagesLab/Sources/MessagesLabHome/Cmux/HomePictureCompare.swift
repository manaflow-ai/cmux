import AppKit

/// cmux: Before and After in the large picture viewer, in one of three ``Style``s (the user, 2026-11-07: "dragging
/// the thing around left/right to see before/after is not good either"). Side by side (the default) shows both
/// whole; a click on one, or Space, flips to it alone, large, and Space or a click flips it in place to its pair
/// (B and A pick one); the slider keeps the old drag. Both pictures fit the same frame (the first picture's aspect),
/// so in the flip and on the slider a pixel lines up with its pair.
@MainActor
final class HomePictureCompare: NSView {
    /// How the pair shows.
    enum Style: Int, CaseIterable, Sendable {
        /// Both pictures whole, next to each other.
        case sideBySide
        /// One picture large; a flip shows its pair in the same place.
        case flip
        /// One over the other with a divider a drag moves.
        case slider
    }

    var first: CGImage? { didSet { needsDisplay = true } }
    var second: CGImage? { didSet { needsDisplay = true } }
    var firstTitle = "" { didSet { needsDisplay = true } }
    var secondTitle = "" { didSet { needsDisplay = true } }
    /// Where the divider is, 0 (all second) to 1 (all first).
    var split: CGFloat = 0.5 { didSet { split = min(1, max(0, split)); needsDisplay = true } }
    var style: Style = .sideBySide { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// In the flip, whether the second picture (After) shows.
    var showsSecond = false { didSet { needsDisplay = true } }
    /// The style changed from inside (a click on a side-by-side picture opens the flip); the viewer's bar follows.
    var onStyle: (Style) -> Void = { _ in }

    /// The space between the two pictures side by side.
    private static let gap: CGFloat = 16

    override var isFlipped: Bool { true }

    /// Shows the flip with the first picture (`second` false) or the second.
    func flip(toSecond second: Bool) {
        if style != .flip { style = .flip; onStyle(.flip) }
        showsSecond = second
    }

    /// The pictures' frame in `bounds`: side by side, both pictures' frames together; else the first picture's
    /// aspect, as large as fits, centred.
    var pictureFrame: CGRect {
        guard style == .sideBySide else { return fitted(in: bounds) }
        let (a, b) = sideFrames
        return a.union(b)
    }

    /// The first picture's aspect, as large as fits in `box`, centred.
    private func fitted(in box: CGRect) -> CGRect {
        let image = first ?? second
        guard let image, image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let w = (CGFloat(image.width) * scale).rounded(), h = (CGFloat(image.height) * scale).rounded()
        return CGRect(x: (box.midX - w / 2).rounded(), y: (box.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Side by side: each picture's frame, each in its half of `bounds`, both the same size.
    private var sideFrames: (CGRect, CGRect) {
        let half = max(0, (bounds.width - Self.gap) / 2)
        let left = fitted(in: CGRect(x: bounds.minX, y: bounds.minY, width: half, height: bounds.height))
        let right = CGRect(x: bounds.maxX - half + (half - left.width) / 2, y: left.minY, width: left.width, height: left.height).integral
        // The pair sits together in the middle, not pushed to the outer edges when the pictures are tall.
        let pull = max(0, (right.minX - left.maxX - Self.gap) / 2)
        return (left.offsetBy(dx: pull, dy: 0), right.offsetBy(dx: -pull, dy: 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        func paint(_ image: CGImage?, in frame: CGRect, clip: CGRect? = nil) {
            guard let image else { return }
            ctx.saveGState()
            ctx.clip(to: clip ?? frame)
            ctx.interpolationQuality = .high
            ctx.translateBy(x: frame.minX, y: frame.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: frame.size))
            ctx.restoreGState()
        }
        switch style {
        case .sideBySide:
            let (a, b) = sideFrames
            paint(first, in: a)
            paint(second, in: b)
            label(firstTitle, at: CGPoint(x: a.minX + 10, y: a.maxY - 10), trailing: false)
            label(secondTitle, at: CGPoint(x: b.minX + 10, y: b.maxY - 10), trailing: false)
        case .flip:
            let frame = fitted(in: bounds)
            paint(showsSecond ? second : first, in: frame)
            label(showsSecond ? secondTitle : firstTitle, at: CGPoint(x: frame.minX + 10, y: frame.maxY - 10), trailing: false)
        case .slider:
            drawSlider(ctx, paint: paint)
        }
    }

    private func drawSlider(_ ctx: CGContext, paint: (CGImage?, CGRect, CGRect?) -> Void) {
        let frame = fitted(in: bounds)
        let x = frame.minX + frame.width * split
        paint(second, frame, CGRect(x: x, y: frame.minY, width: frame.maxX - x, height: frame.height))
        paint(first, frame, CGRect(x: frame.minX, y: frame.minY, width: x - frame.minX, height: frame.height))
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

    /// Side by side, a click on a picture shows it alone (the flip); in the flip a click shows its pair; on the
    /// slider a click or drag moves the divider.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch style {
        case .sideBySide:
            let (a, b) = sideFrames
            if a.contains(p) { flip(toSecond: false) } else if b.contains(p) { flip(toSecond: true) }
        case .flip: if fitted(in: bounds).contains(p) { showsSecond.toggle() }
        case .slider: follow(p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if style == .slider { follow(convert(event.locationInWindow, from: nil)) }
    }

    /// The arrow over the pictures, as over every clickable thing in the app; only the slider's
    /// divider says it drags.
    override func resetCursorRects() {
        if style == .slider { addCursorRect(fitted(in: bounds), cursor: .resizeLeftRight) }
    }

    private func follow(_ p: CGPoint) {
        let frame = fitted(in: bounds)
        guard frame.width > 0 else { return }
        split = (p.x - frame.minX) / frame.width
    }
}
