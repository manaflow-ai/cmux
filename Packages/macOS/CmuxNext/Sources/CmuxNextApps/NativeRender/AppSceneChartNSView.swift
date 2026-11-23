import AppKit
import CmuxNextDesign

/// `Chart` (RFD 0009 slice 4): a sparkline (`kind` `line`, the default) or bars (`bar`) from its
/// `values` (finite numbers, the last 64), across its width and 32 points tall unless a frame sets
/// the height, in its `color` (the accent by default; secondary when subtle). Prominent draws the
/// line thicker with a soft fill under it. The extension sends numbers, never pixels;
/// ``geometry(values:kind:width:height:)`` is the same arithmetic as webviews' `chartGeometry`.
final class AppSceneChartNSView: AppSceneNodeNSView {
    private let marks = CAShapeLayer()
    private let area = CAShapeLayer()
    static let defaultHeight: CGFloat = 32
    static let lineWidth: CGFloat = 1.5
    static let maxValues = 64
    /// The gap between bars, as a fraction of each bar's slot.
    private static let barGap: CGFloat = 0.2

    enum Kind { case line, bar }

    enum Geometry: Equatable {
        case line([CGPoint])
        case bars([CGRect])
    }

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        for shape in [area, marks] {
            shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull()]
            shape.lineJoin = .round
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    private var values: [Double] {
        let all = (node.props["values"]?.arrayValue ?? []).compactMap(\.numberValue).filter(\.isFinite)
        return Array(all.suffix(Self.maxValues))
    }

    private var kind: Kind { node.string("kind") == "bar" ? .bar : .line }

    /// Where the marks go in a `width` by `height` box, y down: a line spans the values' range inset
    /// by half its stroke (a flat series, or one value, runs across the middle); bars stand on zero,
    /// rising above it and hanging below it, and the range always holds zero.
    static func geometry(values: [Double], kind: Kind, width: CGFloat, height: CGFloat) -> Geometry {
        guard let least = values.min(), let most = values.max() else { return kind == .bar ? .bars([]) : .line([]) }
        switch kind {
        case .bar:
            let lo = min(0, least), hi = max(0, most)
            let span = hi - lo == 0 ? 1 : hi - lo
            let y = { (v: Double) in height - CGFloat((v - lo) / span) * height }
            let slot = width / CGFloat(values.count)
            let barWidth = slot * (1 - barGap)
            let zero = y(0)
            return .bars(values.enumerated().map { i, v in
                CGRect(x: CGFloat(i) * slot + (slot - barWidth) / 2, y: min(y(v), zero), width: barWidth, height: abs(y(v) - zero))
            })
        case .line:
            let inset = lineWidth / 2
            let lo = least, hi = most
            let inner = height - 2 * inset
            let y = { (v: Double) in hi == lo ? height / 2 : inset + inner - CGFloat((v - lo) / (hi - lo)) * inner }
            if values.count == 1 { return .line([CGPoint(x: 0, y: y(values[0])), CGPoint(x: width, y: y(values[0]))]) }
            let step = width / CGFloat(values.count - 1)
            return .line(values.enumerated().map { i, v in CGPoint(x: CGFloat(i) * step, y: y(v)) })
        }
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        setAccessibilityLabel("\(kind == .bar ? "bar" : "line") chart of \(values.count) values")
        needsLayout = true
    }

    override func contentHeight(width: CGFloat) -> CGFloat { Self.defaultHeight }

    override func layoutContent(in rect: CGRect) {
        let geometry = Self.geometry(values: values, kind: kind, width: rect.width, height: rect.height)
        let path = CGMutablePath()
        let fill = CGMutablePath()
        switch geometry {
        case .bars(let bars):
            for bar in bars { path.addRect(bar.offsetBy(dx: rect.minX, dy: rect.minY)) }
        case .line(let points):
            let placed = points.map { CGPoint(x: $0.x + rect.minX, y: $0.y + rect.minY) }
            if let first = placed.first, let last = placed.last {
                path.addLines(between: placed)
                fill.move(to: CGPoint(x: first.x, y: rect.maxY))
                fill.addLines(between: placed)
                fill.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                fill.closeSubpath()
            }
        }
        marks.path = path
        area.path = kind == .line && node.componentVariant == .prominent ? fill : nil
    }

    override func paint() {
        performWithTheme {
            let variant = node.componentVariant
            let color = (variant == .subtle ? Palette.textSecondary : node.props["color"]?.sceneColor) ?? Palette.accentFill
            if kind == .bar {
                marks.fillColor = color.cgColor
                marks.strokeColor = nil
            } else {
                marks.fillColor = nil
                marks.strokeColor = color.cgColor
                marks.lineWidth = variant == .prominent ? 2 : Self.lineWidth
            }
            area.fillColor = color.withAlphaComponent(0.14).cgColor
        }
    }
}
