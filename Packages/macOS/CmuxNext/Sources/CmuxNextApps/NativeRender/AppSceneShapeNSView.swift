import AppKit
import CmuxNextDesign

/// `Circle`, `Capsule`, `Rectangle`, `RoundedRectangle` (`cornerRadius`, 4 by default): `fill` and
/// `stroke` (`strokeWidth`, 1 by default) tones; with neither, filled in the secondary tone. `fill` may
/// also be a gradient (``AppSceneGradient``), drawn clipped to the shape. `size`
/// makes it a square of that side; without it, it takes the width it gets and its `frame` height
/// (a shape has no height of its own, so with no frame it draws nothing in a vertical stack).
/// `gradient` paints the fill (or, for a stroked shape, the stroke) with a linear gradient, over a
/// gradient `fill`; `trim` draws part of a stroked outline (a circle's from 12 o'clock, clockwise: a
/// ring gauge); `glow` shines around the drawn outline. Fill, stroke, trim, glow and the outline
/// itself animate with `animation`.
/// `Line` is a stroke along its width: `strokeWidth` thick (1 by default) in `stroke` (the separator ink).
final class AppSceneShapeNSView: AppSceneNodeNSView {
    /// Carries the glow: its shadow follows whatever it draws (the shape, or the masked gradient).
    private let host = CALayer()
    private let shape = CAShapeLayer()
    /// The `gradient`, shown through ``gradientMask`` (the outline's alpha).
    private var gradient: CAGradientLayer?
    private var gradientMask: CAShapeLayer?
    /// The gradient `fill` (``AppSceneGradient``), masked to the outline; made the first time a node asks for one.
    private var fillGradient: CAGradientLayer?
    private let fillGradientMask = CAShapeLayer()

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        let still: [String: any CAAction] = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(),
                                             "position": NSNull(), "strokeStart": NSNull(), "strokeEnd": NSNull(), "lineWidth": NSNull()]
        shape.actions = still
        host.actions = ["bounds": NSNull(), "position": NSNull(), "shadowPath": NSNull()]
        fillGradientMask.actions = still
        host.addSublayer(shape)
        layer?.addSublayer(host)
    }

    override var glowLayer: CALayer? { host }
    override var drawsGradientBackground: Bool { false }
    override var shimmerOutline: CGPath? {
        guard let path = shape.path else { return nil }
        var shift = CGAffineTransform(translationX: host.frame.minX, y: host.frame.minY)
        return path.copy(using: &shift)
    }

    private var side: CGFloat? { node.number("size").map { CGFloat(max(0, $0)) } }
    private var isStroked: Bool { node.props["stroke"]?.stringValue != nil }

    private var lineWidth: CGFloat { CGFloat(max(0, node.number("strokeWidth") ?? 1)) }

    override var contentNaturalWidth: CGFloat? { node.type == .line ? nil : side }
    override func contentHeight(width: CGFloat) -> CGFloat { node.type == .line ? lineWidth : side ?? 0 }

    override func layoutContent(in rect: CGRect) {
        if node.type == .line {
            host.frame = rect
            host.shadowPath = nil
            shape.frame = CGRect(origin: .zero, size: rect.size)
            shape.path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
            shape.lineWidth = 0
            return
        }
        let box = side.map { CGRect(x: rect.minX, y: rect.midY - $0 / 2, width: $0, height: $0) } ?? rect
        animateFrame(host, box)
        animateFrame(shape, CGRect(origin: .zero, size: box.size))
        let lineWidth = CGFloat(node.number("strokeWidth") ?? 1)
        let inset = isStroked ? lineWidth / 2 : 0
        let path = CGRect(origin: .zero, size: box.size).insetBy(dx: inset, dy: inset)
        let radius: CGFloat = switch node.type {
        case .circle, .capsule: min(path.width, path.height) / 2
        case .roundedRectangle: CGFloat(node.number("cornerRadius") ?? 4)
        default: 0
        }
        let outline = node.type == .circle
            ? Self.circle(center: CGPoint(x: path.midX, y: path.midY), radius: max(radius, 0), yDown: shape.contentsAreFlipped())
            : CGPath(roundedRect: path, cornerWidth: min(radius, path.width / 2), cornerHeight: min(radius, path.height / 2), transform: nil)
        animateValue(shape, \.path, "path", outline)
        shape.lineWidth = lineWidth
        if let fillGradient {
            // The gradient's points depend on the box's shape, so repaint after a resize.
            if fillGradient.frame.size != box.size { needsDisplay = true }
            fillGradient.frame = CGRect(origin: .zero, size: box.size)
            fillGradientMask.frame = fillGradient.bounds
            fillGradientMask.path = outline
        }
        if let gradient, let gradientMask, let spec = node.gradient {
            animateFrame(gradient, CGRect(origin: .zero, size: box.size))
            gradientMask.frame = gradient.bounds
            animateValue(gradientMask, \.path, "path", outline)
            gradientMask.lineWidth = lineWidth
            let (start, end) = spec.endpoints(yDown: gradient.contentsAreFlipped())
            gradient.startPoint = start
            gradient.endPoint = end
        }
        // An untrimmed glow casts from the outline itself, with no offscreen pass.
        host.shadowPath = node.glow != nil && node.trim == nil
            ? (isStroked ? outline.copy(strokingWithWidth: lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10) : outline) : nil
    }

    /// A circle that starts at 12 o'clock and runs clockwise on screen, so `trim` fills like a gauge.
    static func circle(center: CGPoint, radius: CGFloat, yDown: Bool) -> CGPath {
        let path = CGMutablePath()
        // In a +y-down space angles grow clockwise on screen; in a +y-up one, counterclockwise.
        let top: CGFloat = yDown ? -.pi / 2 : .pi / 2
        path.addArc(center: center, radius: radius, startAngle: top, endAngle: top + (yDown ? 2 : -2) * .pi, clockwise: !yDown)
        path.closeSubpath()
        return path
    }

    override func paint() {
        let stroke = node.props["stroke"]?.sceneColor
        if node.type == .line {
            gradient?.isHidden = true
            fillGradient?.isHidden = true
            shape.fillColor = (stroke ?? node.props["fill"]?.sceneColor ?? Palette.separator).cgColor
            shape.strokeColor = nil
            return
        }
        let fill = node.props["fill"]?.sceneColor ?? (stroke == nil ? Palette.textSecondary : .clear)
        let trim = node.trim
        paintGradient()
        paintFillGradient()
        let painted = gradient == nil
        let fillPainted = painted && fillGradient?.isHidden != false
        animateColor(shape, \.fillColor, "fillColor", fillPainted ? fill.cgColor : (painted ? NSColor.clear.cgColor : nil))
        animateColor(shape, \.strokeColor, "strokeColor", painted ? stroke?.cgColor : nil)
        for outline in [shape, gradientMask].compactMap({ $0 }) {
            animateNumber(outline, \.strokeStart, "strokeStart", trim?.from ?? 0)
            animateNumber(outline, \.strokeEnd, "strokeEnd", trim?.to ?? 1)
        }
    }

    /// The `gradient` fill (or stroke, for a stroked shape), through a mask of the outline.
    private func paintGradient() {
        guard let spec = node.gradient else {
            gradient?.removeFromSuperlayer()
            (gradient, gradientMask) = (nil, nil)
            return
        }
        let fill = gradient ?? Self.makeGradientLayer()
        let mask = gradientMask ?? CAShapeLayer()
        if gradient == nil {
            fill.masksToBounds = false
            fill.cornerRadius = 0
            mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "strokeStart": NSNull(), "strokeEnd": NSNull()]
            mask.path = shape.path
            mask.frame = shape.frame
            mask.lineWidth = shape.lineWidth
            fill.frame = shape.frame
            fill.mask = mask
            host.addSublayer(fill)
            (gradient, gradientMask) = (fill, mask)
            needsLayout = true
        }
        // The mask's alpha is the outline: an opaque fill, or an opaque stroke on a clear fill.
        mask.fillColor = isStroked ? nil : NSColor.black.cgColor
        mask.strokeColor = isStroked ? NSColor.black.cgColor : nil
        animateColors(fill, spec.colors.compactMap { $0.sceneColor?.cgColor })
    }

    /// A gradient `fill` (``AppSceneGradient``), shown through a mask of the outline; hidden under a `gradient`.
    private func paintFillGradient() {
        guard gradient == nil, let spec = AppSceneGradient(node.props["fill"]) else {
            fillGradient?.isHidden = true
            return
        }
        let drawn = fillGradient ?? {
            let made = CAGradientLayer()
            made.actions = ["colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            fillGradientMask.fillColor = NSColor.black.cgColor
            fillGradientMask.path = shape.path
            fillGradientMask.frame = CGRect(origin: .zero, size: shape.frame.size)
            made.mask = fillGradientMask
            made.frame = shape.frame
            host.insertSublayer(made, below: shape)
            fillGradient = made
            return made
        }()
        drawn.isHidden = false
        spec.apply(to: drawn, size: drawn.bounds.size, yDown: drawn.contentsAreFlipped())
    }
}
