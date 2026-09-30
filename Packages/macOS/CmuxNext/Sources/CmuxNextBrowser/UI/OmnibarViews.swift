import AppKit
import CmuxNextDesign
import QuartzCore

/// The omnibar's rounded background: gray at rest, darker on hover, white
/// with a neutral ring while editing, and plain white while it is the top of
/// the suggestion card.
final class OmnibarPillView: NSView {
    enum State { case idle, editing, card }

    var state: State = .idle { didSet { if oldValue != state { refresh(animated: true) } } }
    private var isHovering = false { didSet { if oldValue != isHovering { refresh(animated: true) } } }
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = OmnibarStyle.barCornerRadius
        layer?.cornerCurve = .continuous
        refresh(animated: false)
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

    private func refresh(animated: Bool) {
        let fill: NSColor = switch state {
        case .idle: isHovering ? OmnibarStyle.barHoverFill : OmnibarStyle.barFill
        case .editing, .card: OmnibarStyle.cardFill
        }
        let ring = state == .editing ? OmnibarStyle.ringWidth : 0
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Motion.reduced)
        CATransaction.setAnimationDuration(0.12)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = OmnibarStyle.ring.cgColor
        }
        layer?.borderWidth = ring
        CATransaction.commit()
    }
}

/// The part of the suggestion card that surrounds the bar: 3 pt above and
/// 6 pt past each side, rounded at the top only. The dropdown panel continues
/// it below the bar, so bar and rows read as one card (Helium's popup).
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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = OmnibarStyle.cardFill.cgColor
        }
    }
}
