import AppKit
import CmuxNextDesign

/// `insertionLine`: a thick rounded caret where the new divider appears
/// (along the strip for a center drop, down a column gap), over a faint
/// tint of the incoming region, with the label in that region.
final class InsertionLineRenderer: DropOverlayRenderer {
    let style = DropOverlayStyle.insertionLine
    let view = DropOverlayRenderers.container()
    private let tint = DropOverlayRenderers.shape()
    private let line = DropOverlayRenderers.shape()
    private let label = DropOverlayLabel()

    init() {
        view.layer?.addSublayer(tint)
        view.layer?.addSublayer(line)
        view.addSubview(label.field)
    }

    func update(_ frame: DropOverlayFrame) {
        let width = CGFloat(DropOverlayTunables.lineWidth.value)
        let region = frame.zone == .column ? frame.target : frame.region
        let caret = DropOverlayGeometry.insertionLine(region: region, zone: frame.zone, width: width,
                                                      length: CGFloat(DropOverlayTunables.lineLength.value))
        Motion.transaction(nil) {
            tint.path = DropOverlayGeometry.roundedRect(frame.target, frame.cornerRadius)
            tint.opacity = Float(DropOverlayTunables.lineRegionOpacity.value)
            line.path = DropOverlayGeometry.roundedRect(caret, width / 2)
        }
        label.place(in: frame.target, frame: frame)
    }

    func applyTheme() {
        view.performWithTheme {
            let color = Palette.tunable(DropOverlayTunables.color.value)
            tint.fillColor = color.cgColor
            line.fillColor = color.cgColor
            label.applyTheme(Palette.textPrimary)
        }
    }
}

/// `hairline`, `dashed` and `corners`: one stroked path around the target
/// in the line color, and the label. No fill, no glass.
final class StrokeRenderer: DropOverlayRenderer {
    let style: DropOverlayStyle
    let view = DropOverlayRenderers.container()
    private let stroke = DropOverlayRenderers.shape()
    private let label = DropOverlayLabel()

    init(style: DropOverlayStyle) {
        self.style = style
        stroke.fillColor = nil
        stroke.lineCap = .round
        stroke.lineJoin = .round
        view.layer?.addSublayer(stroke)
        view.addSubview(label.field)
    }

    private var devicePixel: CGFloat { 1 / max(view.window?.backingScaleFactor ?? 2, 1) }

    func update(_ frame: DropOverlayFrame) {
        let width: CGFloat
        let path: CGPath
        switch style {
        case .dashed:
            width = CGFloat(DropOverlayTunables.dashWidth.value)
            path = DropOverlayGeometry.roundedRect(frame.target.insetBy(dx: width / 2, dy: width / 2), frame.cornerRadius)
        case .corners:
            width = CGFloat(DropOverlayTunables.cornerWidth.value)
            path = DropOverlayGeometry.bracketsPath(frame.target.insetBy(dx: width / 2, dy: width / 2),
                                                    length: CGFloat(DropOverlayTunables.cornerLength.value))
        default:
            let tuned = CGFloat(DropOverlayTunables.hairlineWidth.value)
            width = tuned > 0 ? tuned : devicePixel
            path = DropOverlayGeometry.roundedRect(frame.target.insetBy(dx: width / 2, dy: width / 2), frame.cornerRadius)
        }
        Motion.transaction(nil) {
            stroke.lineWidth = width
            stroke.path = path
            stroke.lineDashPattern = style == .dashed
                ? [NSNumber(value: DropOverlayTunables.dashLength.value), NSNumber(value: DropOverlayTunables.dashGap.value)] : nil
            stroke.opacity = style == .hairline ? Float(DropOverlayTunables.hairlineOpacity.value) : 1
        }
        label.place(in: frame.target, frame: frame)
    }

    func applyTheme() {
        view.performWithTheme {
            stroke.strokeColor = Palette.tunable(DropOverlayTunables.color.value).cgColor
            label.applyTheme(Palette.textPrimary)
        }
    }
}
