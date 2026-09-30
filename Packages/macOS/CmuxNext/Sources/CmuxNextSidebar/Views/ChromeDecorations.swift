import AppKit
import CmuxNextDesign
import QuartzCore

/// Layer-hosting view under the rows that draws the selection pill and the
/// drag gap as plain CALayers (no views), animated with CA springs.
final class SidebarDecorationView: NSView {
    private let pill = CALayer()
    private let gap = CALayer()

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

    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.backgroundColor = resolvedCGColor(Palette.selectionFill)
        gap.backgroundColor = resolvedCGColor(Palette.hoverFill)
        pill.cornerRadius = SidebarStyle.rowCornerRadius
        gap.cornerRadius = SidebarStyle.rowCornerRadius
        CATransaction.commit()
    }

    /// Moves the pill under the active row (nil hides it).
    func setPill(_ frame: CGRect?, animated: Bool) {
        move(pill, to: frame, animated: animated, perceptualDuration: 0.26, bounce: 0.08)
    }

    /// Shows the drag gap placeholder (nil hides it).
    func setGap(_ frame: CGRect?, animated: Bool) {
        move(gap, to: frame, animated: animated, perceptualDuration: 0.32, bounce: 0.12)
    }

    private func move(_ layer: CALayer, to frame: CGRect?, animated: Bool, perceptualDuration: TimeInterval, bounce: CGFloat) {
        updateColors()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let visible = frame != nil
        let wasVisible = layer.opacity > 0
        let animate = animated && !Motion.reduceMotion
        if let frame {
            if animate && wasVisible && layer.frame != frame {
                let current = layer.presentation() ?? layer
                for (key, from, to) in [
                    ("position", NSValue(point: current.position), NSValue(point: CGPoint(x: frame.midX, y: frame.midY))),
                    ("bounds", NSValue(rect: current.bounds), NSValue(rect: CGRect(origin: .zero, size: frame.size))),
                ] {
                    let spring = CASpringAnimation(perceptualDuration: perceptualDuration, bounce: bounce)
                    spring.keyPath = key
                    spring.fromValue = from
                    spring.toValue = to
                    layer.add(spring, forKey: key)
                }
            }
            layer.frame = frame
        }
        let opacity: Float = visible ? 1 : 0
        if layer.opacity != opacity {
            if animate {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
                fade.toValue = opacity
                fade.duration = 0.16
                layer.add(fade, forKey: "opacity")
            }
            layer.opacity = opacity
        }
    }
}
