import AppKit
import CmuxNextDesign

/// `Circle`, `Capsule`, `Rectangle`, `RoundedRectangle` (`cornerRadius`, 4 by default): `fill` and
/// `stroke` (`strokeWidth`, 1 by default) tones; with neither, filled in the secondary tone. `size`
/// makes it a square of that side; without it, it takes the width it gets and its `frame` height
/// (a shape has no height of its own, so with no frame it draws nothing in a vertical stack).
final class AppSceneShapeNSView: AppSceneNodeNSView {
    private let shape = CAShapeLayer()

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        shape.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shape)
    }

    private var side: CGFloat? { node.number("size").map { CGFloat(max(0, $0)) } }

    override var contentNaturalWidth: CGFloat? { side }
    override func contentHeight(width: CGFloat) -> CGFloat { side ?? 0 }

    override func layoutContent(in rect: CGRect) {
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
        shape.fillColor = (node.props["fill"]?.sceneColor ?? (stroke == nil ? Palette.textSecondary : .clear)).cgColor
        shape.strokeColor = stroke?.cgColor
    }
}
