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

    /// Springs each view to its frame (its superview's coordinates) on the render server, all from one
    /// begin time, so the views of one change move in lockstep: a model change's rows, their group lines
    /// and the chat history blocks (`RowMotion`, perf step 4: an insert at the top moved every row below
    /// with AppKit's spring, which writes each row's frame on the main thread every display frame).
    /// The model frames change at once through the animator in a zero-length group, which also stops a
    /// move AppKit still runs on a view (a plain set does not, and AppKit would write over it). Nothing
    /// is left to run on the main thread per frame; the springs end on their own (`settlingTime`).
    /// `token`: the spring (`.move`, or a new row's `SidebarInsertMotion.token`). `travel`: when set, each view's edges
    /// are drawn at most that many points from where they end (`SidebarInsertMotion.cap`), so a new row at the top moves
    /// the rows below it by the nudge, not a row height; 0 moves nothing (the frames land at once). The cap holds for
    /// what is drawn, not for each spring: the offset this batch's springs still carry (an insert 30 ms before) counts
    /// toward it, and those springs give way to one that starts there, so two quick inserts never stack two nudges.
    static func move<View: NSView>(_ moves: [(View, NSRect)], in host: NSView, _ token: MotionSpring = .move, travel: CGFloat? = nil) {
        // Out of a window nothing draws a spring (and none would end), and with movement off nothing moves: the
        // frames land at once, and a spring an earlier move left on any of these views ends with them (it would
        // keep carrying its offset over the frame, and keep the next snap from showing).
        guard Motion.sidebar.animatesMovement, host.window != nil, Motion.canAnimate(in: host) else {
            stop(moves.map(\.0))
            let moving = moves.filter { $0.0.frame != $0.1 }
            if !moving.isEmpty { Motion.withoutAnimation { for (view, frame) in moving { view.animator().frame = frame } } }
            return
        }
        let moving = moves.filter { $0.0.frame != $0.1 }
        guard !moving.isEmpty else { return }
        // Where each view is drawn now: its model geometry, plus (under a cap) what this batch's springs still carry.
        let sampled = CACurrentMediaTime()
        let starts = moving.map { view, _ in
            view.layer.map { layer in
                let start = start(of: layer)
                guard travel != nil else { return start }
                let carried = inFlight(on: layer, at: sampled)
                return (CGPoint(x: start.0.x + carried.0.x, y: start.0.y + carried.0.y),
                        CGSize(width: start.1.width + carried.1.width, height: start.1.height + carried.1.height))
            }
        }
        Motion.withoutAnimation { for (view, frame) in moving { view.animator().frame = frame } }
        // The springs start after the frame update, which can take a while at many rows, so none begins already advanced.
        let now = CACurrentMediaTime()
        for ((view, _), start) in zip(moving, starts) {
            guard let layer = view.layer, var start else { continue }
            if let travel {
                // One spring from where the view is drawn, capped, replaces the ones that carried it there.
                stop([view])
                start = capped(start, of: layer, travel: travel)
            }
            addDelta(to: layer, position: start.0, size: start.1, now: now, key: batchKey, token)
        }
    }

    /// Takes the springs `move(_:in:)` added off these views, so each shows its model frame now: a change
    /// without motion (a reload without animation, Reduce Motion) or the display going to sleep mid-move.
    /// A drag's own springs (`move(_:to:)`) keep running, as AppKit's frame snap left them before.
    static func stop<View: NSView>(_ views: [View]) {
        let prefixes = ["\(batchKey).position.", "\(batchKey).size."]
        for layer in views.compactMap(\.layer) {
            for key in layer.animationKeys() ?? [] where prefixes.contains(where: { key.hasPrefix($0) }) {
                layer.removeAnimation(forKey: key)
            }
        }
    }

    /// The key prefix of the springs `move(_:in:)` adds (`stop` takes only those off).
    static let batchKey = "move"

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

    /// The offset this batch's springs (`batchKey`) still add to `layer`'s position and size at media time `now`.
    private static func inFlight(on layer: CALayer, at now: CFTimeInterval) -> (CGPoint, CGSize) {
        var position = CGPoint.zero, size = CGSize.zero
        let local = layer.convertTime(now, from: nil)
        for key in layer.animationKeys() ?? [] where key.hasPrefix("\(batchKey).") {
            guard let spring = layer.animation(forKey: key) as? CASpringAnimation, spring.isAdditive,
                  let from = spring.fromValue as? NSValue else { continue }
            let left = 1 - MotionPath.springProgress(spring, at: local - spring.beginTime)
            if spring.keyPath == "position" {
                position.x += from.pointValue.x * left
                position.y += from.pointValue.y * left
            } else if spring.keyPath == "bounds.size" {
                size.width += from.sizeValue.width * left
                size.height += from.sizeValue.height * left
            }
        }
        return (position, size)
    }

    /// The start `start` (a layer's position and size) with each edge within `travel` points of the layer's model
    /// geometry, its destination (`SidebarInsertMotion.cap`).
    private static func capped(_ start: (CGPoint, CGSize), of layer: CALayer, travel: CGFloat) -> (CGPoint, CGSize) {
        let anchor = layer.anchorPoint
        func rect(_ position: CGPoint, _ size: CGSize) -> CGRect {
            CGRect(x: position.x - anchor.x * size.width, y: position.y - anchor.y * size.height, width: size.width, height: size.height)
        }
        let near = SidebarInsertMotion.cap(rect(start.0, start.1), toward: rect(layer.position, layer.bounds.size), travel: travel)
        return (CGPoint(x: near.minX + anchor.x * near.width, y: near.minY + anchor.y * near.height), near.size)
    }

    /// `now`: the media time the spring starts at (one for a batch, `move(_:in:)`); `key`: the springs' key prefix;
    /// `token`: their spring.
    private static func addDelta(to layer: CALayer, position: CGPoint, size: CGSize, now: CFTimeInterval = CACurrentMediaTime(),
                                 key: String = "drag", _ token: MotionSpring = .move) {
        serial &+= 1
        // The spring starts now, when it is added, not at the start of this run-loop turn: after a long main-thread
        // update in the same turn (a drag's first move builds its hit geometry, ~30 ms at 1,000 rows) the first frame
        // showed the spring 30 ms on, a 12-17 pt step (hitch3/dphb0 scenario 4, cx-8quut).
        let begin = layer.convertTime(now, from: nil)
        let dp = CGPoint(x: position.x - layer.position.x, y: position.y - layer.position.y)
        let ds = CGSize(width: size.width - layer.bounds.width, height: size.height - layer.bounds.height)
        // The model is already at the destination. A compositor sample before the explicit
        // begin time must carry the starting delta too, or it flashes the destination first.
        if dp != .zero {
            let animation = Motion.sidebar.springAnimation(token, "position", from: NSValue(point: dp), to: NSValue(point: .zero))
            animation.isAdditive = true
            animation.beginTime = begin
            animation.fillMode = .backwards
            layer.add(animation, forKey: "\(key).position.\(serial)")
        }
        if ds != .zero {
            let animation = Motion.sidebar.springAnimation(token, "bounds.size", from: NSValue(size: ds), to: NSValue(size: .zero))
            animation.isAdditive = true
            animation.beginTime = begin
            animation.fillMode = .backwards
            layer.add(animation, forKey: "\(key).size.\(serial)")
        }
    }

    /// Fades `view` to `alpha` (a placeholder row a drag shows or hides).
    static func fade(_ view: NSView, to alpha: CGFloat) {
        guard view.alphaValue != alpha else { return }
        Motion.feedback.animate(.hover, in: view) { view.animator().alphaValue = alpha }
    }
}
