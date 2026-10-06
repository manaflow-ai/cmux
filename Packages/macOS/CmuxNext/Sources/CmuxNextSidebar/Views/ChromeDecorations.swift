import AppKit
import CmuxNextDesign
import QuartzCore

/// Layer-hosting view under the rows that draws the selection pill and the
/// drag gap as plain CALayers (no views), animated with CA springs.
final class SidebarDecorationView: NSView {
    private let pill = CALayer()
    private let gap = CALayer()
    /// The selection pill (tests).
    var pillLayer: CALayer { pill }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Assigning the layer before wantsLayer makes this view layer-hosting,
        // so its sublayers are ours to manage.
        let root = CALayer()
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        for decoration in [gap, pill] {
            decoration.cornerCurve = .continuous
            decoration.opacity = 0
            root.addSublayer(decoration)
        }
        // Flat gray pill and gap: no rim, no shadow, no border.
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
            pill.backgroundColor = Palette.selectionFill.cgColor
            gap.backgroundColor = Palette.hoverFill.cgColor
        }
        pill.cornerRadius = SidebarStyle.rowCornerRadius
        gap.cornerRadius = SidebarStyle.rowCornerRadius
        CATransaction.commit()
    }

    /// Where the active row's pill goes: the sidebar's one selection
    /// highlight (`SidebarSelectionHighlight`) draws it; this view then draws
    /// no pill of its own.
    var onPill: ((CGRect?, Bool) -> Void)?

    /// Moves the pill under the active row (nil hides it).
    func setPill(_ frame: CGRect?, animated: Bool) {
        if let onPill { return onPill(frame, animated) }
        move(pill, to: frame, animated: animated, spring: .selection)
    }

    /// Moves the pill and gap by `dy` at once, from where they show now,
    /// with the rows and the scroll offset (the sidebar keeping what the
    /// user sees after a close; close-focus.md): no visible change.
    func shift(by dy: CGFloat) {
        for layer in [pill, gap] {
            let current = layer.presentation()?.frame ?? layer.frame
            layer.removeAnimation(forKey: "position")
            layer.removeAnimation(forKey: "bounds")
            Motion.transaction(nil) { layer.frame = current.offsetBy(dx: 0, dy: dy) }
        }
    }

    /// Shows the drag gap placeholder (nil hides it).
    func setGap(_ frame: CGRect?, animated: Bool) {
        move(gap, to: frame, animated: animated, spring: .move)
    }

    /// Springs `layer` to `frame` from its on-screen position (a new move
    /// mid-glide retargets without a jump) and fades it in or out.
    private func move(_ layer: CALayer, to frame: CGRect?, animated: Bool, spring: MotionSpring) {
        updateColors()
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
