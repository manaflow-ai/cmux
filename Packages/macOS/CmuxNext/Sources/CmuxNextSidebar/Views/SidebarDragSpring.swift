import AppKit
import CmuxNextDesign
import QuartzCore

/// The drag's one spring (DESIGN "Drag feel" 3, 6, 7): every row, block,
/// tile, section card and the lifted card moves with additive `.move`
/// springs. The model frame changes at once (so hit tests, a later apply
/// and the probe read the destination) and an additive spring carries what
/// is on screen from the old frame to it. A retarget mid-flight adds one
/// more spring from the old model value: the presented value and its
/// velocity stay continuous, so a gap that opens, closes and opens again
/// never steps, and an apply whose frames equal the model moves nothing.
@MainActor enum SidebarDragSpring {
    private static var serial = 0
    private static let geometryPaths: Set<String> = ["position", "bounds", "bounds.size", "bounds.origin", "frameOrigin", "frameSize"]

    /// Springs `view` to `frame` (its superview's coordinates).
    static func move(_ view: NSView, to frame: NSRect) {
        guard view.frame != frame else { return }
        guard let layer = view.layer, Motion.sidebar.animatesMovement, Motion.canAnimate(in: view) else {
            Motion.withoutAnimation { view.frame = frame }
            return
        }
        let (position, size) = start(of: layer)
        Motion.withoutAnimation { view.frame = frame }
        addDelta(to: layer, position: position, size: size)
    }

    /// Springs a plain layer (a section card, a line) to `frame`.
    static func move(_ layer: CALayer, to frame: CGRect) {
        guard layer.frame != frame else { return }
        let (position, size) = start(of: layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        CATransaction.commit()
        guard Motion.sidebar.animatesMovement else { return }
        addDelta(to: layer, position: position, size: size)
    }

    /// Where the spring starts: the model value, so the additive springs
    /// already running keep carrying their part; a non-additive geometry
    /// animation (an AppKit animator move from an earlier apply) would pin
    /// the layer to its own end value, so it is replaced by the value it
    /// shows now.
    private static func start(of layer: CALayer) -> (CGPoint, CGSize) {
        let keys = (layer.animationKeys() ?? []).filter { key in
            guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation, let path = animation.keyPath else { return false }
            return geometryPaths.contains(path) && !animation.isAdditive
        }
        guard !keys.isEmpty, let shown = layer.presentation() else { return (layer.position, layer.bounds.size) }
        for key in layer.animationKeys() ?? [] {
            if let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath, geometryPaths.contains(path) { layer.removeAnimation(forKey: key) }
        }
        return (shown.position, shown.bounds.size)
    }

    private static func addDelta(to layer: CALayer, position: CGPoint, size: CGSize) {
        serial &+= 1
        // The spring starts now, when it is added, not at the start of this run-loop turn: after a long main-thread
        // update in the same turn (a drag's first move builds its hit geometry, ~30 ms at 1,000 rows) the first frame
        // showed the spring 30 ms on, a 12-17 pt step (hitch3/dphb0 scenario 4, cx-8quut).
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil)
        let dp = CGPoint(x: position.x - layer.position.x, y: position.y - layer.position.y)
        let ds = CGSize(width: size.width - layer.bounds.width, height: size.height - layer.bounds.height)
        if dp != .zero {
            let animation = Motion.sidebar.springAnimation(.move, "position", from: NSValue(point: dp), to: NSValue(point: .zero))
            animation.isAdditive = true
            animation.beginTime = begin
            layer.add(animation, forKey: "drag.position.\(serial)")
        }
        if ds != .zero {
            let animation = Motion.sidebar.springAnimation(.move, "bounds.size", from: NSValue(size: ds), to: NSValue(size: .zero))
            animation.isAdditive = true
            animation.beginTime = begin
            layer.add(animation, forKey: "drag.size.\(serial)")
        }
    }

    /// Fades `view` to `alpha` (a placeholder row a drag shows or hides).
    static func fade(_ view: NSView, to alpha: CGFloat) {
        guard view.alphaValue != alpha else { return }
        Motion.feedback.animate(.hover, in: view) { view.animator().alphaValue = alpha }
    }
}
