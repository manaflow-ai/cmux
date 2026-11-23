import AppKit

/// A shape's `trim` (`{from?, to, lineCap?}`, SwiftUI's `trim(from:to:)`): the fractions of its
/// stroked outline to draw, clamped to 0...1 with `from` never past `to`, and the cap at each end
/// (`butt`, the default, or `round`). Nil for anything with no finite `to`, so a bad value draws the
/// whole outline, as the web renderer does (`sceneTrim`).
nonisolated struct AppSceneTrim: Equatable {
    var from: CGFloat
    var to: CGFloat
    var lineCap: CAShapeLayerLineCap

    init?(_ value: AppJSON?) {
        guard let fields = value?.objectValue, let to = fields["to"]?.numberValue, to.isFinite else { return nil }
        let clamp = { (n: Double) in CGFloat(min(max(n, 0), 1)) }
        let start = fields["from"]?.numberValue.flatMap { $0.isFinite ? $0 : nil } ?? 0
        from = clamp(start)
        self.to = max(from, clamp(to))
        lineCap = fields["lineCap"]?.stringValue == "round" ? .round : .butt
    }

    /// A circle that starts at 12 o'clock and runs clockwise on screen, so a trim fills like a
    /// gauge. `yDown` is whether the layer's space has +y down on screen.
    static func circle(center: CGPoint, radius: CGFloat, yDown: Bool) -> CGPath {
        let path = CGMutablePath()
        // In a +y-down space angles grow clockwise on screen; in a +y-up one, counterclockwise.
        let top: CGFloat = yDown ? -.pi / 2 : .pi / 2
        path.addArc(center: center, radius: radius, startAngle: top, endAngle: top + (yDown ? 2 : -2) * .pi, clockwise: !yDown)
        path.closeSubpath()
        return path
    }
}
