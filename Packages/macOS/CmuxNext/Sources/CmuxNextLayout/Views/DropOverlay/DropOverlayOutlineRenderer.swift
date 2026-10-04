import AppKit
import CmuxNextDesign

/// `outline` (the default, tab-dnd): a rounded border in the accent color
/// exactly around the rect the drop creates (the split half, the pane, the
/// column gap, the dock band), no fill. It moves between targets with a
/// Core Animation spring (`Motion.set`), so the compositor draws every
/// frame and the main thread runs no frame clock; Reduce Motion snaps. A
/// refused target draws the border in the danger color with the reason in
/// a small chip.
final class OutlineRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.outline
    let view = DropOverlayRenderers.container()
    private let ring = CALayer()
    private let chip = PassthroughView()
    private let label = DropOverlayLabel()
    /// The rect the ring is at or heading to; nil while hidden.
    private var shown: CGRect?
    private var refused = false

    var drivesOwnMotion: Bool { true }
    /// The ring's model state (debug and tests): its frame in the plane,
    /// border width, fill, and whether the reason chip shows.
    var ringFrame: CGRect { ring.frame }
    var ringWidth: CGFloat { ring.borderWidth }
    var ringHasFill: Bool { ring.backgroundColor != nil }
    var ringOpacity: Float { ring.opacity }
    var showsChip: Bool { !chip.isHidden }

    init() {
        ring.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "opacity": NSNull(),
                        "borderColor": NSNull(), "borderWidth": NSNull()]
        ring.backgroundColor = nil
        ring.opacity = 0
        view.layer?.addSublayer(ring)
        chip.wantsLayer = true
        chip.layer?.cornerRadius = Metrics.space2
        chip.isHidden = true
        chip.addSubview(label.field)
        view.addSubview(chip)
    }

    func update(_ frame: DropOverlayFrame) {
        let rect = frame.finalTarget
        let width = CGFloat(DropOverlayTunables.outlineStrokeWidth.value)
        if refused != frame.refused {
            refused = frame.refused
            applyTheme()
        }
        Motion.withoutAnimation { ring.borderWidth = width }
        if shown != rect {
            let appearing = shown == nil
            if appearing {
                // Grows into place from a little inside the target.
                let share = CGFloat(DropOverlayTunables.appearInset.value)
                place(rect.insetBy(dx: rect.width * share, dy: rect.height * share), radius: frame.cornerRadius, animated: false)
            }
            place(rect, radius: frame.cornerRadius, animated: frame.animated)
            if appearing || ring.opacity < 1 {
                if frame.animated { Motion.set(ring, "opacity", to: NSNumber(value: 1), fade: .fadeIn) } else { setNow("opacity", 1) }
            }
            shown = rect
        }
        placeChip(in: rect, frame: frame)
    }

    func hide(animated: Bool) {
        shown = nil
        chip.isHidden = true
        if animated { Motion.set(ring, "opacity", to: NSNumber(value: 0), fade: .fadeOut) } else { setNow("opacity", 0) }
    }

    func applyTheme() {
        view.performWithTheme {
            let color = refused ? Palette.danger : Palette.tunable(DropOverlayTunables.outlineColor.value)
            Motion.withoutAnimation { ring.borderColor = color.cgColor }
            chip.layer?.backgroundColor = Palette.elevatedBackground.cgColor
            label.applyTheme(refused ? Palette.danger : Palette.textPrimary)
        }
    }

    // MARK: Private

    /// Moves the ring to `rect` (the plane's flipped coordinates) with the
    /// overlay spring, from wherever it is on screen now.
    private func place(_ rect: CGRect, radius: CGFloat, animated: Bool) {
        let bounds = NSValue(rect: CGRect(origin: .zero, size: rect.size))
        let position = NSValue(point: CGPoint(x: rect.midX, y: rect.midY))
        let corner = NSNumber(value: Double(max(0, min(radius, min(rect.width, rect.height) / 2))))
        guard animated else {
            setNow("bounds", bounds)
            setNow("position", position)
            setNow("cornerRadius", corner)
            return
        }
        let token = DropOverlayTunables.spring.value
        Motion.set(ring, "bounds", to: bounds, spring: token)
        Motion.set(ring, "position", to: position, spring: token)
        Motion.set(ring, "cornerRadius", to: corner, spring: token)
    }

    private func setNow(_ keyPath: String, _ value: Any) {
        ring.removeAnimation(forKey: keyPath)
        Motion.withoutAnimation { ring.setValue(value, forKeyPath: keyPath) }
    }

    /// The reason chip of a refused target, centered in it. Other targets
    /// show no label: the border alone says where the tab lands.
    private func placeChip(in rect: CGRect, frame: DropOverlayFrame) {
        let text = frame.refused ? frame.label : ""
        let inner = rect.insetBy(dx: Metrics.space3, dy: Metrics.space3)
        let labelFrame = DropOverlayFrame(target: inner, region: inner, zone: frame.zone, bounds: frame.bounds,
                                          cornerRadius: 0, label: text, showsLabel: !text.isEmpty)
        label.place(in: CGRect(origin: .zero, size: inner.size), frame: labelFrame)
        chip.isHidden = label.field.isHidden
        guard !chip.isHidden else { return }
        let field = label.field.frame
        let pad = Metrics.space2
        chip.frame = CGRect(x: inner.minX + field.minX - pad, y: inner.minY + field.minY - pad / 2,
                            width: field.width + pad * 2, height: field.height + pad).integral
        label.field.frame.origin = CGPoint(x: pad, y: pad / 2)
    }
}
