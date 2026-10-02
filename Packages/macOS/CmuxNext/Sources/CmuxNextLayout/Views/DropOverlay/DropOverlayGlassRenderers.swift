import AppKit
import CmuxNextDesign

/// `glassFill` (the original overlay) and `morph`: Liquid Glass filling the
/// target with the label centered in it. Morph differs only in where it
/// starts and which spring moves it (`DropHighlightView`).
final class GlassFillRenderer: DropOverlayRenderer {
    let style: DropOverlayStyle
    let view = DropOverlayRenderers.container()
    let surface: OverlaySurfaceView
    private let label = NSTextField(labelWithString: "")

    init(style: DropOverlayStyle, material: OverlayMaterial?) {
        self.style = style
        surface = OverlaySurfaceView(material: material)
        let content = surface.contentView
        label.font = Typography.bodyEmphasized
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Metrics.space3),
        ])
        view.addSubview(surface)
    }

    var material: OverlayMaterial? { surface.material }
    func pinMaterial(_ material: OverlayMaterial?) { surface.materialOverride = material }

    func update(_ frame: DropOverlayFrame) {
        surface.frame = frame.target
        surface.cornerRadius = frame.cornerRadius
        label.font = Typography.bodyEmphasized
        if label.stringValue != frame.label { label.stringValue = frame.label }
        label.isHidden = !frame.showsLabel || frame.label.isEmpty || frame.finalTarget.width < CGFloat(DropOverlayTunables.labelMinWidth.value)
    }

    func applyTheme() {
        view.performWithTheme { label.textColor = Palette.textPrimary }
        surface.applyTheme()
    }
}

/// `glassOutline`: a band of glass tracing the target's rounded edge (the
/// surface masked to a ring), so the content stays readable inside.
final class GlassOutlineRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.glassOutline
    let view = DropOverlayRenderers.container()
    private let surface: OverlaySurfaceView
    private let ring = DropOverlayRenderers.shape()
    private let label = DropOverlayLabel()

    init(material: OverlayMaterial?) {
        surface = OverlaySurfaceView(material: material)
        surface.wantsLayer = true
        ring.fillRule = .evenOdd
        ring.fillColor = NSColor.black.cgColor
        surface.layer?.mask = ring
        view.addSubview(surface)
        view.addSubview(label.field)
    }

    var material: OverlayMaterial? { surface.material }
    func pinMaterial(_ material: OverlayMaterial?) { surface.materialOverride = material }

    func update(_ frame: DropOverlayFrame) {
        surface.frame = frame.target
        surface.cornerRadius = frame.cornerRadius
        let bounds = CGRect(origin: .zero, size: frame.target.size)
        Motion.transaction(nil) {
            ring.frame = bounds
            ring.path = DropOverlayGeometry.ringPath(bounds, cornerRadius: frame.cornerRadius,
                                                     width: CGFloat(DropOverlayTunables.outlineWidth.value))
        }
        label.place(in: frame.target, frame: frame)
    }

    func applyTheme() {
        view.performWithTheme { label.applyTheme(Palette.textPrimary) }
        surface.applyTheme()
    }
}

/// `insetCard`: a faint tint over the target with a glass card in its
/// middle carrying the split glyph and the label.
final class InsetCardRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.insetCard
    let view = DropOverlayRenderers.container()
    private let tint = DropOverlayRenderers.shape()
    private let card: OverlaySurfaceView
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var zone: DropOverlayZone?

    init(material: OverlayMaterial?) {
        card = OverlaySurfaceView(material: material)
        view.layer?.addSublayer(tint)
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = Metrics.space3
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.font = Typography.bodyEmphasized
        label.lineBreakMode = .byTruncatingTail
        let content = card.contentView
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Metrics.space4),
        ])
        view.addSubview(card)
    }

    var material: OverlayMaterial? { card.material }
    func pinMaterial(_ material: OverlayMaterial?) { card.materialOverride = material }

    func update(_ frame: DropOverlayFrame) {
        Motion.transaction(nil) {
            tint.path = DropOverlayGeometry.roundedRect(frame.target, frame.cornerRadius)
            tint.opacity = Float(DropOverlayTunables.cardRegionOpacity.value)
        }
        let rect = DropOverlayGeometry.insetCard(target: frame.target, fraction: DropOverlayTunables.cardWidthFraction.value,
                                                 maxWidth: DropOverlayTunables.cardMaxWidth.value, height: DropOverlayTunables.cardHeight.value)
        card.frame = rect
        card.cornerRadius = min(Metrics.panelCornerRadius, rect.height / 2)
        if zone != frame.zone {
            zone = frame.zone
            icon.image = NSImage(systemSymbolName: Self.symbol(frame.zone), accessibilityDescription: nil)
        }
        icon.isHidden = !DropOverlayTunables.cardShowsIcon.value
        label.font = Typography.bodyEmphasized
        if label.stringValue != frame.label { label.stringValue = frame.label }
        label.isHidden = !frame.showsLabel || frame.label.isEmpty || rect.width < CGFloat(DropOverlayTunables.labelMinWidth.value)
    }

    func applyTheme() {
        view.performWithTheme {
            tint.fillColor = Palette.tunable(DropOverlayTunables.color.value).cgColor
            label.textColor = Palette.textPrimary
            icon.contentTintColor = Palette.textPrimary
        }
        card.applyTheme()
    }

    static func symbol(_ zone: DropOverlayZone) -> String {
        switch zone {
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .center: "rectangle.stack"
        case .column: "rectangle.split.3x1"
        }
    }
}
