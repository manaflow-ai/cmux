import AppKit
import CmuxNextDesign

/// `outline` (the default): the shared `DropOutlineRing` exactly around
/// the rect the drop creates (the split half, the pane, the column gap, the
/// dock band, a strip's insert slot), as classic cmux draws it: the accent
/// at 0.25 inside a 2 pt accent border, radius 8, moved by the compositor. A refused target draws the ring in the danger color with
/// the reason in a small chip.
final class OutlineRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.outline
    let view = DropOverlayRenderers.container()
    private let ring = DropOutlineRing()
    private let chip = PassthroughView()
    private let label = DropOverlayLabel()

    var drivesOwnMotion: Bool { true }
    /// The ring's model state (debug and tests).
    var ringFrame: CGRect { ring.layer.frame }
    var ringWidth: CGFloat { ring.layer.borderWidth }
    var ringOpacity: Float { ring.layer.opacity }
    var showsChip: Bool { !chip.isHidden }

    init() {
        view.layer?.addSublayer(ring.layer)
        chip.wantsLayer = true
        chip.layer?.cornerRadius = Metrics.space2
        chip.isHidden = true
        chip.addSubview(label.field)
        view.addSubview(chip)
    }

    func update(_ frame: DropOverlayFrame) {
        // A refused target and a tab strip's insert slot draw the border only.
        let fill = frame.fills && !frame.refused ? DropOutlineTunables.fillOpacity.value : 0
        let colorsChanged = ring.isRefused != frame.refused || ring.fillOpacity != fill || ring.rect == nil
        ring.show(frame.finalTarget, cornerRadius: frame.cornerRadius, refused: frame.refused, animated: frame.animated,
                  spring: DropOverlayTunables.spring.value, appearInset: CGFloat(DropOverlayTunables.appearInset.value),
                  fillOpacity: fill)
        // The ring resolved its colors outside the theme scope; resolve them again inside it.
        if colorsChanged { applyTheme() }
        placeChip(in: frame.finalTarget, frame: frame)
    }

    func hide(animated: Bool) {
        chip.isHidden = true
        ring.hide(animated: animated)
    }

    func applyTheme() {
        view.performWithTheme {
            ring.applyTheme()
            chip.layer?.backgroundColor = Palette.elevatedBackground.cgColor
            label.applyTheme(ring.isRefused ? Palette.danger : Palette.textPrimary)
        }
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
