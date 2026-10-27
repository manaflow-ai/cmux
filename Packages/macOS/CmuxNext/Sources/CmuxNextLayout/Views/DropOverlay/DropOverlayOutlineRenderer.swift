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
    /// Outlines of the panes the drop resizes, at their final frames (the
    /// final-layout preview): a 1 pt line of the ring color at half strength,
    /// no fill, so the new pane (filled) reads as the change.
    private var companions: [CALayer] = []
    private var companionRadius: CGFloat = 0

    var drivesOwnMotion: Bool { true }
    /// The ring's model state (debug and tests).
    var ringFrame: CGRect { ring.layer.frame }
    var ringWidth: CGFloat { ring.layer.borderWidth }
    var ringOpacity: Float { ring.layer.opacity }
    /// The ring's layer, for the springs on it (tests).
    var ringLayer: CALayer { ring.layer }
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
                  fillOpacity: fill, springs: frame.springsOnRenderServer ? .additive(shownIn: view) : .replacing)
        // The ring resolved its colors outside the theme scope; resolve them again inside it.
        if colorsChanged { applyTheme() }
        placeCompanions(frame.refused ? [] : frame.companions, cornerRadius: frame.cornerRadius)
        placeChip(in: frame.finalTarget, frame: frame)
    }

    func hide(animated: Bool) {
        chip.isHidden = true
        placeCompanions([], cornerRadius: 0)
        ring.hide(animated: animated)
    }

    func applyTheme() {
        view.performWithTheme {
            ring.applyTheme()
            let line = Palette.tunable(DropOutlineTunables.color.value)
            for layer in companions { layer.borderColor = line.withAlphaComponent(line.alphaComponent * 0.6).cgColor }
            chip.layer?.backgroundColor = Palette.elevatedBackground.cgColor
            label.applyTheme(ring.isRefused ? Palette.danger : Palette.textPrimary)
        }
    }

    /// Shows one outline per rect (snapped: they mark the result, they do not move between targets).
    private func placeCompanions(_ rects: [CGRect], cornerRadius: CGFloat) {
        let grew = rects.count > companions.count
        while companions.count < rects.count {
            let layer = CALayer()
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "opacity": NSNull(),
                             "borderColor": NSNull(), "borderWidth": NSNull(), "hidden": NSNull()]
            layer.borderWidth = 1
            view.layer?.insertSublayer(layer, below: ring.layer)
            companions.append(layer)
        }
        if grew { applyTheme() }
        Motion.withoutAnimation {
            for (index, layer) in companions.enumerated() {
                guard index < rects.count else { layer.isHidden = true; continue }
                let rect = rects[index]
                layer.isHidden = false
                layer.frame = rect
                layer.cornerRadius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
            }
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
