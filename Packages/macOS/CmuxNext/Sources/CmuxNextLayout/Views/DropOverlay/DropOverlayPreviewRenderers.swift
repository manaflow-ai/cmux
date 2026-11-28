import AppKit
import CmuxNextDesign

/// `splitPreview`: the panes the drop creates, at their final sizes. The
/// incoming pane is glass with the label; the existing pane keeps an
/// outline, so the user sees both halves and the gap between them. A
/// center or column drop shows the incoming pane only.
final class SplitPreviewRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.splitPreview
    let view = DropOverlayRenderers.container()
    private let existing = DropOverlayRenderers.shape()
    private let incoming: OverlaySurfaceView
    private let label = DropOverlayLabel()

    init(material: OverlayMaterial?) {
        incoming = OverlaySurfaceView(material: material)
        view.layer?.addSublayer(existing)
        view.addSubview(incoming)
        view.addSubview(label.field)
    }

    var material: OverlayMaterial? { incoming.material }
    func pinMaterial(_ material: OverlayMaterial?) { incoming.materialOverride = material }

    func update(_ frame: DropOverlayFrame) {
        let split = DropOverlayGeometry.splitPreview(region: frame.region, zone: frame.zone,
                                                     gap: CGFloat(DropOverlayTunables.splitGap.value))
        // A floating target (no pane chrome, column gap) keeps its own rect.
        let incomingRect = frame.zone.splits ? split.incoming : frame.target
        incoming.frame = incomingRect
        incoming.cornerRadius = frame.cornerRadius
        Motion.transaction(nil) {
            if let rect = split.existing {
                existing.path = DropOverlayGeometry.roundedRect(rect.insetBy(dx: 0.5, dy: 0.5), frame.cornerRadius)
                existing.opacity = Float(DropOverlayTunables.splitExistingOpacity.value)
            } else {
                existing.opacity = 0
            }
        }
        label.place(in: incomingRect, frame: frame)
    }

    func applyTheme() {
        view.performWithTheme {
            let line = Palette.tunable(DropOverlayTunables.color.value)
            existing.strokeColor = line.cgColor
            existing.fillColor = line.withAlphaComponent(line.alphaComponent * 0.08).cgColor
            existing.lineWidth = 1
            existing.lineDashPattern = [NSNumber(value: Double(Metrics.space2)), NSNumber(value: Double(Metrics.space2))]
            label.applyTheme(Palette.textPrimary)
        }
        incoming.applyTheme()
    }
}

/// `tabGhost`: a glass tab pill where the tab will sit in the destination
/// pane's strip, over a faint tint of the target.
final class TabGhostRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.tabGhost
    let view = DropOverlayRenderers.container()
    private let tint = DropOverlayRenderers.shape()
    private let pill: OverlaySurfaceView
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(material: OverlayMaterial?) {
        pill = OverlaySurfaceView(material: material)
        view.layer?.addSublayer(tint)
        icon.image = DropOverlayGlyph.image(.workspaceNew)
        label.font = Typography.bodyEmphasized
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = Metrics.space3
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = pill.contentView
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.tabContentLeadingInset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -Metrics.space4),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        view.addSubview(pill)
    }

    var material: OverlayMaterial? { pill.material }
    func pinMaterial(_ material: OverlayMaterial?) { pill.materialOverride = material }

    func update(_ frame: DropOverlayFrame) {
        Motion.transaction(nil) {
            tint.path = DropOverlayGeometry.roundedRect(frame.target, frame.cornerRadius)
            tint.opacity = Float(DropOverlayTunables.ghostRegionOpacity.value)
        }
        let inset = max(0, (Metrics.tabStripHeight - Metrics.tabHeight) / 2) + Metrics.tabBackgroundInset
        let rect = DropOverlayGeometry.tabPill(target: frame.target, width: CGFloat(DropOverlayTunables.ghostWidth.value),
                                               height: Metrics.tabHeight, inset: max(inset, Metrics.space1))
        pill.frame = rect
        pill.cornerRadius = Metrics.itemCornerRadius
        label.font = Typography.bodyEmphasized
        if label.stringValue != frame.label { label.stringValue = frame.label }
        label.isHidden = !frame.showsLabel || frame.label.isEmpty
    }

    func applyTheme() {
        view.performWithTheme {
            tint.fillColor = Palette.tunable(DropOverlayTunables.color.value).cgColor
            label.textColor = Palette.textPrimary
            icon.contentTintColor = Palette.textSecondary
        }
        pill.applyTheme()
    }
}
