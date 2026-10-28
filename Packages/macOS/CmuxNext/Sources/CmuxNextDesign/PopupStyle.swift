public import AppKit
public import CmuxNextDesignTokens

/// One look for every native popover and menu (hover cards, group editors,
/// the icon picker, page info, the palette's actions menu): the web's popup
/// surface (webviews/src/ui/popupSurface.css, #18729) in AppKit. Small-radius
/// rects, compact rows and one subtle shadow (`elevation`); each surface keeps its own
/// material and theme colors. `PopupStyleTests` holds the two in step. Hover cards
/// keep the shadow and rows but take the floating glass panels' larger radius
/// (`HoverCardPanel.cornerRadius`).
public struct PopupStyle: Sendable {
    /// The style every native popover uses.
    public static let standard = PopupStyle()

    public let cornerRadius: CGFloat = DesignTokens.radiusPopup
    public let padding: CGFloat = DesignTokens.space1
    public let rowHeight: CGFloat = DesignTokens.controlRow
    public let rowCornerRadius: CGFloat = 5
    public let openDuration: TimeInterval = 0.12

    /// The one popover shadow: the raised step of the elevation scale.
    public var elevation: Elevation { Self.elevation2 }

    public init() {}

    /// The transparent band a popover window keeps around its card, so the
    /// card's shadow is never clipped by the window.
    public var shadowMargin: CGFloat { elevation.blur + elevation.offset }

    /// The window frame for a card at `card` (screen coordinates).
    public func windowFrame(forCard card: CGRect) -> CGRect {
        card.insetBy(dx: -shadowMargin, dy: -shadowMargin)
    }

    /// The card's frame in a popover window at `window`.
    public func cardFrame(inWindow window: CGRect) -> CGRect {
        window.insetBy(dx: shadowMargin, dy: shadowMargin)
    }
}

/// One step of the shared elevation scale (Leo 2026-10-14, no dramatic shadows): a tight,
/// low-alpha black drop under a surface, whose thin rim carries the edge. The web scale is the
/// same numbers (`--elevation-1`/`--elevation-2`, webviews/src/pages/shared/desktop.css;
/// subtle-elevation.test.ts holds the two in step).
public struct Elevation: Sendable, Equatable {
    /// How far the shadow falls below the surface, in points.
    public let offset: CGFloat
    /// The blur, as CSS and `NSShadow.shadowBlurRadius` measure it.
    public let blur: CGFloat
    /// The black's alpha (a layer's `shadowOpacity` over an opaque shadow color).
    public let alpha: CGFloat

    public init(offset: CGFloat, blur: CGFloat, alpha: CGFloat) {
        self.offset = offset
        self.blur = blur
        self.alpha = alpha
    }

    /// Core Animation's `shadowRadius` for this blur (about half a CSS blur).
    public var layerRadius: CGFloat { blur / 2 }

    /// The `CALayer.shadowOffset` that falls below the surface: negative y in AppKit's y-up
    /// layers, positive in a flipped (y-down) one.
    public func layerOffset(flipped: Bool = false) -> CGSize {
        CGSize(width: 0, height: flipped ? offset : -offset)
    }

    /// This elevation as an `NSShadow` in black (AppKit's offset is y-up: negative falls below).
    public func shadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -offset)
        return shadow
    }
}

extension PopupStyle {
    /// Rows, cards and inline surfaces: `0 1px 2px` black at 7%.
    public static let elevation1 = Elevation(offset: 1, blur: 2, alpha: 0.07)
    /// Popovers, menus, the palette, hover cards, toasts and a lifted tab: `0 2px 6px` black at 11%.
    public static let elevation2 = Elevation(offset: 2, blur: 6, alpha: 0.11)
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
    /// Clear room kept around the shadow band, so a card that moves inside its window (the hover
    /// card's slide, `HoverCardPanel`) is not clipped by the window. 0 for a popover that never
    /// moves its card.
    public var travelMargin: CGFloat = 0 {
        didSet { if travelMargin != oldValue { placeCard() } }
    }
    /// The card's corner radius, which the shadow follows: the popup radius, or a popup that
    /// copies another app's radius (the Extensions bubble, Chrome's 12).
    public var cornerRadius: CGFloat = PopupStyle.standard.cornerRadius {
        didSet {
            guard cornerRadius != oldValue else { return }
            if let surface = card as? OverlaySurfaceView { surface.cornerRadius = cornerRadius }
            placeCard()
        }
    }

    /// `card` sizes by its frame (the host lays it out). An
    /// `OverlaySurfaceView` card takes the popup radius.
    public init(card: NSView) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = true
        if let surface = card as? OverlaySurfaceView { surface.cornerRadius = PopupStyle.standard.cornerRadius }
        let elevation = PopupStyle.standard.elevation
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = Float(elevation.alpha)
        shadowLayer.shadowRadius = elevation.layerRadius
        shadowLayer.shadowOffset = elevation.layerOffset()
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
        let margin = PopupStyle.standard.shadowMargin + travelMargin
        guard bounds.width >= 2 * margin, bounds.height >= 2 * margin else { return }
        let frame = bounds.insetBy(dx: margin, dy: margin)
        card.frame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = cornerRadius
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
