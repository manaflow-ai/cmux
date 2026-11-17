import AppKit
import CmuxNextDesign

/// `Circle`, `Capsule`, `Rectangle`, `RoundedRectangle` (`cornerRadius`, 4 by default): `fill` and
/// `stroke` (`strokeWidth`, 1 by default) tones; with neither, filled in the secondary tone. `size`
/// makes it a square of that side; without it, it takes the width it gets and its `frame` height
/// (a shape has no height of its own, so with no frame it draws nothing in a vertical stack).
/// `Line` is a stroke along its width: `strokeWidth` thick (1 by default) in `stroke` (the separator ink).
final class AppSceneShapeNSView: AppSceneNodeNSView {
    private let shape = CAShapeLayer()

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        shape.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shape)
    }

    private var side: CGFloat? { node.number("size").map { CGFloat(max(0, $0)) } }

    private var lineWidth: CGFloat { CGFloat(max(0, node.number("strokeWidth") ?? 1)) }

    override var contentNaturalWidth: CGFloat? { node.type == .line ? nil : side }
    override func contentHeight(width: CGFloat) -> CGFloat { node.type == .line ? lineWidth : side ?? 0 }

    override func layoutContent(in rect: CGRect) {
        if node.type == .line {
            shape.frame = rect
            shape.path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
            shape.lineWidth = 0
            return
        }
        let box = side.map { CGRect(x: rect.minX, y: rect.midY - $0 / 2, width: $0, height: $0) } ?? rect
        shape.frame = box
        let lineWidth = CGFloat(node.number("strokeWidth") ?? 1)
        let inset = node.props["stroke"]?.stringValue == nil ? 0 : lineWidth / 2
        let path = CGRect(origin: .zero, size: box.size).insetBy(dx: inset, dy: inset)
        let radius: CGFloat = switch node.type {
        case .circle, .capsule: min(path.width, path.height) / 2
        case .roundedRectangle: CGFloat(node.number("cornerRadius") ?? 4)
        default: 0
        }
        shape.path = node.type == .circle
            ? CGPath(ellipseIn: CGRect(x: path.midX - radius, y: path.midY - radius, width: 2 * radius, height: 2 * radius), transform: nil)
            : CGPath(roundedRect: path, cornerWidth: min(radius, path.width / 2), cornerHeight: min(radius, path.height / 2), transform: nil)
        shape.lineWidth = lineWidth
    }

    override func paint() {
        let stroke = node.props["stroke"]?.sceneColor
        if node.type == .line {
            shape.fillColor = (stroke ?? node.props["fill"]?.sceneColor ?? Palette.separator).cgColor
            shape.strokeColor = nil
            return
        }
        shape.fillColor = (node.props["fill"]?.sceneColor ?? (stroke == nil ? Palette.textSecondary : .clear)).cgColor
        shape.strokeColor = stroke?.cgColor
    }
}
