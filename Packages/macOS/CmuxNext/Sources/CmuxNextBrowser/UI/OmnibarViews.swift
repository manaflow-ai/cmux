import AppKit
import CmuxNextDesign
import QuartzCore

/// The omnibar's rounded background: at rest the glass material
/// (`OmnibarGlassLook`, the theme fill when glass is off), a stronger tint
/// on hover, a neutral ring while editing, and the plain card fill while it
/// is the top of the suggestion card (the card is opaque, so the bar joins
/// it).
final class OmnibarPillView: NSView {
    enum State { case idle, editing, card }

    var state: State = .idle { didSet { if oldValue != state { refresh(animated: true) } } }
    private var isHovering = false { didSet { if oldValue != isHovering { refresh(animated: true) } } }
    private var tracking: NSTrackingArea?
    /// The look in effect; follows the design picker live.
    private(set) var look = OmnibarGlassLook.current { didSet { if oldValue != look { rebuildMaterial() } } }
    /// The glass under the bar, built while the look has a material.
    private var glass: GlassPanelView?
    /// Ends with the view (the loop holds it weakly).
    private var lookLoop: ObservationLoop?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        rebuildMaterial()
        lookLoop = ObservationLoop { [weak self] in
            let next = OmnibarGlassLook.current
            self?.look = next
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Hover is tracked on the whole bar, which sits above this view.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    override func layout() {
        super.layout()
        applyShape()
    }

    /// Glass draws only with a material and without Reduce Transparency.
    private var drawsGlass: Bool {
        look.material != .off && !ReduceTransparency.shared.isEnabled
    }

    private func rebuildMaterial() {
        if drawsGlass {
            let style: Glass.Style = look.material == .clear ? .clear : .regular
            if let glass {
                glass.style = style
            } else {
                let panel = GlassPanelView(style: style, cornerRadius: 0)
                panel.translatesAutoresizingMaskIntoConstraints = false
                addSubview(panel, positioned: .below, relativeTo: nil)
                NSLayoutConstraint.activate([
                    panel.leadingAnchor.constraint(equalTo: leadingAnchor),
                    panel.trailingAnchor.constraint(equalTo: trailingAnchor),
                    panel.topAnchor.constraint(equalTo: topAnchor),
                    panel.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                glass = panel
            }
        } else {
            glass?.removeFromSuperview()
            glass = nil
        }
        applyShape()
        refresh(animated: false)
    }

    private func applyShape() {
        let radius = look.resolvedCornerRadius(barHeight: bounds.height > 0 ? bounds.height : OmnibarStyle.barHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = radius
        glass?.cornerRadius = radius
        if look.shadow && drawsGlass && state != .card {
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 6
            layer?.shadowOffset = CGSize(width: 0, height: -1)
            layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        } else {
            layer?.shadowOpacity = 0
            layer?.shadowPath = nil
        }
        CATransaction.commit()
    }

    private func refresh(animated: Bool) {
        let ring = state == .editing ? OmnibarStyle.ringWidth : 0
        let glassy = drawsGlass && state != .card
        glass?.isHidden = !glassy
        Motion.transaction(animated ? .hover : nil) {
            performWithTheme {
                let fill: NSColor
                if glassy {
                    // The glass draws the surface; the layer adds only the
                    // hover lift over it.
                    fill = isHovering && state == .idle ? OmnibarStyle.chipHoverFill : .clear
                    glass?.tintColor = look.tintColor(boost: state == .editing ? 0.15 : 0)
                    layer?.shadowColor = Palette.shadow.cgColor
                } else {
                    fill = switch state {
                    case .idle: isHovering ? OmnibarStyle.barHoverFill : OmnibarStyle.barFill
                    case .editing, .card: OmnibarStyle.cardFill
                    }
                }
                layer?.backgroundColor = fill.cgColor
                layer?.borderColor = OmnibarStyle.ring.cgColor
            }
            layer?.borderWidth = Metrics.lineWidth(ring)
        }
        applyShape()
    }
}

/// The part of the suggestion card that surrounds the bar: 3 pt above and
/// 6 pt past each side, rounded at the top only. The dropdown panel continues
/// it below the bar, so bar and rows read as one card.
final class OmnibarCardTopView: NSView {
    private let card = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        card.cornerRadius = OmnibarStyle.cardCornerRadius
        card.cornerCurve = .continuous
        card.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        card.shadowOpacity = 0.16
        card.shadowRadius = 8
        card.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(card)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = bounds
        // Extend the shadow shape down past the seam, where the panel's
        // own shadow takes over, so no line shows between the two.
        let shape = CGRect(x: 0, y: -40, width: bounds.width, height: bounds.height + 40)
        card.shadowPath = CGPath(roundedRect: shape, cornerWidth: OmnibarStyle.cardCornerRadius, cornerHeight: OmnibarStyle.cardCornerRadius, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        performWithTheme {
            card.backgroundColor = OmnibarStyle.cardFill.cgColor
        }
    }
}
