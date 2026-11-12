import AppKit

/// The material under a ``CmuxDialogView``: the sheet surface's glass with the popups' one shadow. Every cmux
/// dialog draws on it: a browser tab's JavaScript alert, confirm, prompt and Leave site? dialog, an HTTP
/// sign-in, and the app's own confirms.
///
/// The card floats in the overlay panel, a clear window over the window it covers (a Chromium page, the
/// main window). Liquid Glass there has nothing in its own window to bend: its lens bent the clear pixels
/// into a dark 1 px outline under the sheet's rim and made the corner read as two shapes (Lawrence
/// 2026-11-07, a Leave site? dialog over Gmail: "weird roundness", "weird border"). So the glass is the
/// frosted blur of what is behind the window (`prefersBlurToLiquidGlass`), with the sheet's rim as its one
/// edge; Reduce Transparency keeps the opaque surface.
@MainActor
final class CmuxDialogCardSurface: NSView {
    /// The card's material: the blur, opaque under Reduce Transparency.
    let glass: OverlaySurfaceView
    /// The layer that casts the card's shadow, behind the glass: shaped by the card's rounded rect and cut
    /// away under it, so it never darkens the translucent glass (``PopupHostView``'s shadow).
    let shadowLayer = CALayer()
    private let shadowCutout = CAShapeLayer()

    /// A card drawing `content` on its glass; `activeLook` keeps the key-window glass while the card fades out.
    init(content: NSView, activeLook: ActiveLookScope?) {
        glass = Glass.makeSurface(.sheet, content: content, activeLook: activeLook)
        glass.samplesBehindWindow = true
        glass.prefersBlurToLiquidGlass = true
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        let elevation = PopupStyle.standard.elevation
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = Float(elevation.alpha)
        shadowLayer.shadowRadius = elevation.layerRadius
        shadowLayer.shadowOffset = elevation.layerOffset()
        shadowCutout.fillRule = .evenOdd
        shadowLayer.mask = shadowCutout
        layer?.addSublayer(shadowLayer)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override func layout() {
        super.layout()
        placeShadow()
    }

    /// Shapes the shadow to the card's rect at the glass's corner, cut away under the card.
    private func placeShadow() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // CoreGraphics refuses a corner wider than half the rect.
        let radius = min(glass.cornerRadius, min(bounds.width, bounds.height) / 2)
        let shape = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let band = PopupStyle.standard.shadowMargin * 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = shape
        let cutout = CGMutablePath()
        cutout.addRect(bounds.insetBy(dx: -band, dy: -band))
        cutout.addPath(shape)
        shadowCutout.frame = bounds
        shadowCutout.path = cutout
        CATransaction.commit()
    }
}
