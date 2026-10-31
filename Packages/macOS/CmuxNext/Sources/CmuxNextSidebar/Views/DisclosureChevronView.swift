import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// A group header's disclosure chevron that turns between closed (pointing right) and open (pointing down)
/// (Lawrence msg 15763: "should animate rotation of the chevron when i open/close group").
///
/// One right-pointing glyph turns a quarter turn on the sidebar's motion gate, so a user's fold turns it as the
/// rows slide (`MotionSpring.appear` opening, `.disappear` closing, the springs the rows use). Reduce Motion,
/// animations off and a change nobody here asked for set the new angle at once. The glyph is a layer the view
/// owns, filled with ``contentTintColor`` through the image's alpha, so the turn is about its center: AppKit owns a
/// view's own layer geometry (anchor at the origin) and would turn it about a corner.
final class DisclosureChevronView: NSView {
    /// The glyph: a fill in ``contentTintColor`` masked by the chevron image, turned about its center.
    private let glyph = CALayer()
    private let shape = CALayer()
    /// The glyph's side, in points.
    var glyphSide: CGFloat = Metrics.smallIconSize { didSet { if glyphSide != oldValue { needsLayout = true } } }
    /// The chevron's ink.
    var contentTintColor: NSColor? { didSet { paint() } }
    /// The glyph shown, and the window scale it was drawn for (nil before a window).
    private var image: NSImage?
    private var shownScale: CGFloat?
    /// Whether the chevron points down (the group is open).
    private(set) var isOpen = false

    /// The glyph's turn, in radians, for `open`. Core Animation turns a positive angle counterclockwise in an
    /// unflipped layer, so a quarter turn clockwise (right to down) is negative there and positive in a flipped one.
    private func angle(open: Bool) -> CGFloat {
        guard open else { return 0 }
        return glyph.contentsAreFlipped() ? .pi / 2 : -.pi / 2
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(glyph)
        glyph.mask = shape
        shape.contentsGravity = .resizeAspect
        let still: [String: any CAAction] = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(),
                                             "contents": NSNull(), "transform": NSNull()]
        glyph.actions = still
        shape.actions = still
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Points the chevron down (`open`) or right. `animated` turns it on the sidebar's motion gate, which sets the
    /// angle at once under Reduce Motion or with animations off; otherwise it takes the angle at once.
    func setOpen(_ open: Bool, animated: Bool) {
        let changed = open != isOpen
        isOpen = open
        let target = angle(open: open)
        guard changed, animated else {
            glyph.removeAnimation(forKey: Self.rotation)
            Motion.sidebar.transaction(nil) { setTurn(target) }
            return
        }
        Motion.sidebar.set(glyph, Self.rotation, to: target, spring: open ? .appear : .disappear)
    }

    static let rotation = "transform.rotation.z"

    /// Sets the glyph's model turn to `angle` about its center: the turn is the glyph's only transform, so this is
    /// the value `transform.rotation.z` animates, set as a typed transform rather than by key-value coding.
    private func setTurn(_ angle: CGFloat) { glyph.transform = CATransform3DMakeRotation(angle, 0, 0, 1) }

    /// The chevron image (a template glyph pointing right). The view always shows the one chevron glyph, so an image
    /// of the size it already shows, at the same window scale, is not drawn again.
    func setImage(_ image: NSImage?) {
        guard image?.size != self.image?.size || (image == nil) != (self.image == nil)
                || window?.backingScaleFactor != shownScale else { return }
        self.image = image
        if let image { glyphSide = max(image.size.width, image.size.height) }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        Motion.sidebar.transaction(nil) {
            shownScale = window?.backingScaleFactor
            shape.contents = image?.layerContents(forContentsScale: scale)
            shape.contentsScale = scale
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        glyph.contentsScale = scale
        shape.contentsScale = scale
        let shown = image
        image = nil
        setImage(shown)
    }

    override func layout() {
        super.layout()
        Motion.sidebar.transaction(nil) {
            let side = min(glyphSide, bounds.width, bounds.height)
            glyph.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
            shape.frame = glyph.bounds
            // A flip of the layer tree after the last turn (first layout in a window) keeps the glyph's direction.
            if glyph.animation(forKey: Self.rotation) == nil { setTurn(angle(open: isOpen)) }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = (contentTintColor ?? .secondaryLabelColor).cgColor }
        Motion.sidebar.transaction(nil) { glyph.backgroundColor = color }
    }
}
