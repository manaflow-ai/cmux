public import AppKit

/// One look for every native popover and menu (hover cards, group editors,
/// the icon picker, page info, the palette's actions menu): the web's popup
/// surface (webviews/src/ui/popupSurface.css, #18729) in AppKit. Small-radius
/// rects, compact rows and one subtle shadow; each surface keeps its own
/// material and theme colors. `PopupStyleTests` holds the two in step.
public struct PopupStyle: Sendable {
    /// The style every native popover uses.
    public static let standard = PopupStyle()

    public let cornerRadius: CGFloat = 8
    public let padding: CGFloat = 4
    public let rowHeight: CGFloat = 28
    public let rowCornerRadius: CGFloat = 5
    public let rowPaddingInline: CGFloat = 8
    public let openDuration: TimeInterval = 0.12

    /// The one shadow, `0 2px 8px` black at 12%.
    public let shadowOffset: CGFloat = 2
    public let shadowBlur: CGFloat = 8
    public let shadowAlpha: CGFloat = 0.12

    public init() {}

    /// The transparent band a popover window keeps around its card, so the
    /// card's shadow is never clipped by the window.
    public var shadowMargin: CGFloat { shadowBlur + shadowOffset }

    /// The shadow as an `NSShadow`, for a card that casts its own (AppKit's
    /// offset is y-up: negative falls below).
    public func shadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
        shadow.shadowBlurRadius = shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
        return shadow
    }

    /// The window frame for a card at `card` (screen coordinates).
    public func windowFrame(forCard card: CGRect) -> CGRect {
        card.insetBy(dx: -shadowMargin, dy: -shadowMargin)
    }

    /// The card's frame in a popover window at `window`.
    public func cardFrame(inWindow window: CGRect) -> CGRect {
        window.insetBy(dx: shadowMargin, dy: shadowMargin)
    }
}

/// A popover window's content view: its card inset by
/// `PopupStyle.standard.shadowMargin`, with the popup shadow in that band. The host
/// draws the shadow itself, on a layer behind the card shaped by the card's
/// rounded rect and cut away under it, so it is the same on glass,
/// vibrancy and opaque cards, on a card that masks to its bounds, and never
/// darkens a translucent card. The window draws no shadow of its own. A
/// click on the band's clear pixels reaches the window beneath; one on its
/// faint shadow stays with the popover, which ignores it (`hitTest`).
@MainActor
public final class PopupHostView: NSView {
    public let card: NSView
    /// The layer that casts the popup shadow (behind the card).
    public let shadowLayer = CALayer()
    private let shadowCutout = CAShapeLayer()

    /// `card` sizes by its frame (the host lays it out). An
    /// `OverlaySurfaceView` card takes the popup radius.
    public init(card: NSView) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = true
        if let surface = card as? OverlaySurfaceView { surface.cornerRadius = PopupStyle.standard.cornerRadius }
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = Float(PopupStyle.standard.shadowAlpha)
        // Core Animation's radius is about half a CSS blur.
        shadowLayer.shadowRadius = PopupStyle.standard.shadowBlur / 2
        shadowLayer.shadowOffset = CGSize(width: 0, height: -PopupStyle.standard.shadowOffset)
        shadowCutout.fillRule = .evenOdd
        shadowLayer.mask = shadowCutout
        layer?.addSublayer(shadowLayer)
        addSubview(card)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeCard()
    }

    public override func layout() {
        super.layout()
        placeCard()
    }

    /// The card fills the host less the band. A host smaller than the band
    /// (a window not yet placed) leaves the card where it is.
    private func placeCard() {
        let margin = PopupStyle.standard.shadowMargin
        guard bounds.width >= 2 * margin, bounds.height >= 2 * margin else { return }
        let frame = bounds.insetBy(dx: margin, dy: margin)
        card.frame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = PopupStyle.standard.cornerRadius
        let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = shape
        let cutout = CGMutablePath()
        cutout.addRect(bounds)
        cutout.addPath(shape)
        shadowCutout.frame = bounds
        shadowCutout.path = cutout
        CATransaction.commit()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        card.frame.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
}

extension NSPanel {
    /// Makes `card` this popover's content, in the popup style: no window
    /// shadow, a clear window, the card in a `PopupHostView`.
    @MainActor
    @discardableResult
    public func adoptPopupStyle(card: NSView) -> PopupHostView {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        let host = PopupHostView(card: card)
        contentView = host
        return host
    }
}
