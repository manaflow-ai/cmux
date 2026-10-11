import AppKit
import CmuxNextDesign

/// The drop label ("Split Right"): one line, centered in a rect, hidden
/// when the rect is narrower than the tunable minimum or labels are off.
@MainActor
final class DropOverlayLabel {
    let field = NSTextField(labelWithString: "")

    init() {
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.font = Typography.bodyEmphasized
        field.translatesAutoresizingMaskIntoConstraints = true
    }

    /// Centers the label in `rect` (the label's superview coordinates).
    func place(in rect: CGRect, frame: DropOverlayFrame) {
        let minimum = CGFloat(DropOverlayTunables.labelMinWidth.value)
        // The final size decides, so the label does not flicker while the overlay grows.
        let scale = frame.target.width > 0 ? frame.finalTarget.width / frame.target.width : 1
        let hidden = !frame.showsLabel || frame.label.isEmpty || rect.width * scale < minimum || rect.height < Metrics.space6
        if field.isHidden != hidden { field.isHidden = hidden }
        guard !hidden else { return }
        field.font = Typography.bodyEmphasized
        if field.stringValue != frame.label { field.stringValue = frame.label }
        // The natural text size (a truncating label reports no intrinsic width).
        let size = field.cell?.cellSize ?? field.intrinsicContentSize
        let width = min(size.width, max(rect.width - Metrics.space3 * 2, 0))
        field.frame = CGRect(x: rect.midX - width / 2, y: rect.midY - size.height / 2, width: width, height: size.height).integral
    }

    func applyTheme(_ color: NSColor) {
        field.textColor = color
    }
}

/// A plain flipped view that never takes hits.
final class PassthroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
