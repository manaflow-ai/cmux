import AppKit
import CmuxNextDesign
import QuartzCore

/// Layer-hosting view under the rows that draws the drag gap and each open
/// group's members' line as plain CALayers (no views), animated with CA
/// springs. The selection highlight is not here: each selected row and item
/// paints its own fill in place (SIDEBAR-SELECTION-NO-TRAVEL-ANIMATION).
final class SidebarDecorationView: NSView {
    private let gap = CALayer()
    /// One members' line per open group (cx-qno.17: one layer from under the
    /// header bar to the last member, so no row gap breaks it).
    private var lines: [GroupID: (layer: CALayer, color: GroupColor)] = [:]
    /// Lines of closed or gone groups while they shrink and fade out.
    private var leavingLines: [CALayer] = []

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
            for line in lines.values { line.layer.backgroundColor = line.color.headerFill.cgColor }
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
        for line in lines.values {
            let shown = line.layer.presentation()?.frame ?? line.layer.frame
            line.layer.removeAllAnimations()
            Motion.transaction(nil) { line.layer.frame = shown.offsetBy(dx: 0, dy: dy) }
        }
        // A line still fading out would stay at the old offset: it goes now.
        leavingLines.forEach { $0.removeFromSuperlayer() }
        leavingLines.removeAll()
    }

    /// Shows one members' line per entry, keyed by group: a kept line
    /// springs to its new frame with the rows, a new one grows down from
    /// its top (the members come out from under the header), and a line
    /// whose group closed or left shrinks up into its header and fades.
    func setGroupLines(_ new: [SidebarGroupLine], animated: Bool) {
        var gone = lines
        for line in new {
            gone[line.group] = nil
            if let existing = lines[line.group] {
                lines[line.group]?.color = line.color
                move(existing.layer, to: line.frame, animated: animated)
            } else {
                let layer = CALayer()
                layer.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "opacity": NSNull()]
                layer.cornerRadius = line.frame.width / 2
                layer.cornerCurve = .continuous
                self.layer?.insertSublayer(layer, below: gap)
                lines[line.group] = (layer, line.color)
                Motion.transaction(nil) { layer.frame = animated ? Self.top(of: line.frame) : line.frame }
                if animated { move(layer, to: line.frame, animated: true) }
            }
        }
        for (group, line) in gone {
            lines[group] = nil
            guard animated else {
                line.layer.removeFromSuperlayer()
                continue
            }
            let shown = line.layer.presentation()?.frame ?? line.layer.frame
            CATransaction.begin()
            let layer = line.layer
            leavingLines.append(layer)
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { // main-proof: CATransaction.h: the completion block is called on the main thread
                    layer.removeFromSuperlayer()
                    self?.leavingLines.removeAll { $0 === layer }
                }
            }
            move(line.layer, to: Self.top(of: shown), animated: true)
            Motion.set(line.layer, "opacity", to: Float(0), fade: .fadeOut)
            CATransaction.commit()
        }
        updateColors()
    }

    /// The line's zero-height start: its top edge, under the header bar.
    private static func top(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 0)
    }

    private func move(_ layer: CALayer, to frame: CGRect, animated: Bool) {
        guard animated else {
            layer.removeAllAnimations()
            return Motion.transaction(nil) { layer.frame = frame }
        }
        // Already there or on the way: a running spring keeps going.
        guard layer.frame != frame else { return }
        Motion.set(layer, "position", to: NSValue(point: CGPoint(x: frame.midX, y: frame.midY)), spring: .move)
        Motion.set(layer, "bounds", to: NSValue(rect: CGRect(origin: .zero, size: frame.size)), spring: .move)
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
