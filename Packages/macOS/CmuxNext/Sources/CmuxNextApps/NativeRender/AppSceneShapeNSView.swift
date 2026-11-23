import AppKit
import CmuxNextDesign

/// `Circle`, `Capsule`, `Rectangle`, `RoundedRectangle` (`cornerRadius`, 4 by default): `fill` and
/// `stroke` (`strokeWidth`, 1 by default) tones; with neither, filled in the secondary tone. `fill` may
/// also be a gradient (``AppSceneGradient``), drawn clipped to the shape. `size`
/// makes it a square of that side; without it, it takes the width it gets and its `frame` height
/// (a shape has no height of its own, so with no frame it draws nothing in a vertical stack).
/// `trim` (``AppSceneTrim``) draws part of the stroked outline with `strokeStart`/`strokeEnd`: a
/// circle's from 12 o'clock, clockwise (a ring gauge). This renderer draws the end state of a trim
/// change; the web renderer sweeps it on `animation`.
/// `Line` is a stroke along its width: `strokeWidth` thick (1 by default) in `stroke` (the separator ink).
final class AppSceneShapeNSView: AppSceneNodeNSView {
    private let shape = CAShapeLayer()
    /// The gradient `fill`, masked to the shape's path; made the first time a node asks for one.
    private var gradient: CAGradientLayer?
    private let gradientMask = CAShapeLayer()

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        shape.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
                         "strokeStart": NSNull(), "strokeEnd": NSNull(), "lineCap": NSNull()]
        gradientMask.actions = shape.actions
        layer?.addSublayer(shape)
    }

    private var side: CGFloat? { node.number("size").map { CGFloat(max(0, $0)) } }
    /// The `trim` of a stroked shape; a shape with no stroke has no outline to trim.
    private var trim: AppSceneTrim? { node.props["stroke"]?.stringValue == nil ? nil : AppSceneTrim(node.props["trim"]) }

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
        let trim = self.trim
        if node.type == .circle, trim != nil {
            // A trimmed circle starts at 12 o'clock and runs clockwise, where the trim counts from.
            shape.path = AppSceneTrim.circle(center: CGPoint(x: path.midX, y: path.midY), radius: max(0, radius),
                                             yDown: shape.contentsAreFlipped())
        } else {
            shape.path = node.type == .circle
                ? CGPath(ellipseIn: CGRect(x: path.midX - radius, y: path.midY - radius, width: 2 * radius, height: 2 * radius), transform: nil)
                : CGPath(roundedRect: path, cornerWidth: min(radius, path.width / 2), cornerHeight: min(radius, path.height / 2), transform: nil)
        }
        shape.lineWidth = lineWidth
        // An untrimmed shape keeps the layer's defaults: the whole outline, butt caps.
        shape.strokeStart = trim?.from ?? 0
        shape.strokeEnd = trim?.to ?? 1
        // An empty arc draws nothing, even with round caps (a zero-length round dash is a dot).
        shape.lineCap = trim.map { $0.to > $0.from ? $0.lineCap : .butt } ?? .butt
        if let gradient {
            // The gradient's points depend on the box's shape, so repaint after a resize.
            if gradient.frame.size != box.size { needsDisplay = true }
            gradient.frame = box
            gradientMask.frame = CGRect(origin: .zero, size: box.size)
            gradientMask.path = shape.path
        }
    }

    override func paint() {
        let stroke = node.props["stroke"]?.sceneColor
        if node.type == .line {
            gradient?.isHidden = true
            shape.fillColor = (stroke ?? node.props["fill"]?.sceneColor ?? Palette.separator).cgColor
            shape.strokeColor = nil
            return
        }
        if let fill = AppSceneGradient(node.props["fill"]) {
            let gradient = gradientLayer()
            gradient.isHidden = false
            fill.apply(to: gradient, size: gradient.bounds.size, yDown: gradient.contentsAreFlipped())
            shape.fillColor = NSColor.clear.cgColor
        } else {
            gradient?.isHidden = true
            shape.fillColor = (node.props["fill"]?.sceneColor ?? (stroke == nil ? Palette.textSecondary : .clear)).cgColor
        }
        shape.strokeColor = stroke?.cgColor
    }

    private func gradientLayer() -> CAGradientLayer {
        if let gradient { return gradient }
        let made = CAGradientLayer()
        made.actions = ["colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        made.mask = gradientMask
        made.frame = shape.frame
        gradientMask.frame = CGRect(origin: .zero, size: shape.frame.size)
        gradientMask.path = shape.path
        layer?.insertSublayer(made, below: shape)
        gradient = made
        return made
    }
}
