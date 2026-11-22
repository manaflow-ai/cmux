import AppKit
import CmuxNextDesign
import QuartzCore

/// Layer-hosting view under the rows that draws the drag gap as a plain
/// CALayer (no views), animated with a CA spring. The selection highlight is
/// not here: each selected row and item paints its own fill in place
/// (SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION).
final class SidebarDecorationView: NSView {
    private let gap = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Assigning the layer before wantsLayer makes this view layer-hosting,
        // so its sublayers are ours to manage.
        let root = CALayer()
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        gap.cornerCurve = .continuous
        gap.opacity = 0
        root.addSublayer(gap)
        // Flat gray gap: no rim, no shadow, no border.
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
    }

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        performWithTheme {
            gap.backgroundColor = Palette.hoverFill.cgColor
        }
        gap.cornerRadius = SidebarStyle.rowCornerRadius
        CATransaction.commit()
    }

    /// Moves the gap by `dy` at once, from where it shows now, with the rows
    /// and the scroll offset (the sidebar keeping what the user sees after a
    /// close; close-focus.md): no visible change.
    func shift(by dy: CGFloat) {
        let current = gap.presentation()?.frame ?? gap.frame
        gap.removeAnimation(forKey: "position")
        gap.removeAnimation(forKey: "bounds")
        Motion.transaction(nil) { gap.frame = current.offsetBy(dx: 0, dy: dy) }
    }

    /// Shows the drag gap placeholder (nil hides it): springs it to `frame`
    /// from its on-screen position (a new move mid-glide retargets without a
    /// jump) and fades it in or out.
    func setGap(_ frame: CGRect?, animated: Bool) {
        updateColors()
        let layer = gap
        let spring = MotionSpring.move
        let visible = frame != nil
        let wasVisible = layer.opacity > 0
        if let frame {
            let position = NSValue(point: CGPoint(x: frame.midX, y: frame.midY))
            let bounds = NSValue(rect: CGRect(origin: .zero, size: frame.size))
            if animated && wasVisible && layer.frame != frame {
                Motion.set(layer, "position", to: position, spring: spring)
                Motion.set(layer, "bounds", to: bounds, spring: spring)
            } else {
                Motion.transaction(nil) { layer.frame = frame }
            }
        }
        let opacity: Float = visible ? 1 : 0
        guard layer.opacity != opacity else { return }
        if animated {
            Motion.set(layer, "opacity", to: opacity, fade: visible ? .fadeIn : .fadeOut)
        } else {
            Motion.transaction(nil) { layer.opacity = opacity }
        }
    }
}
