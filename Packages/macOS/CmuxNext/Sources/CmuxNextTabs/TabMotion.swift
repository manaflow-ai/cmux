import AppKit
import CmuxNextDesign
import QuartzCore

/// Where a tab or a group chip sits in the strip's content (`TabStripView.placed`): its target
/// geometry. The strip writes it once per change and Core Animation shows the motion there
/// (`TabStripMove`); nothing steps on the main thread per frame. Alpha is below 1 only for a
/// collapsing group's members (Chrome's open and close never fade).
struct TabPlace: Equatable {
    var x: CGFloat
    var width: CGFloat
    var alpha: CGFloat = 1

    var maxX: CGFloat { x + max(0, width) }
}

/// One strip change's motion (design-tokens.json `motion.tweens`, Chrome's 200 ms 1-(1-t)^2): every
/// layer whose model geometry the change moved gets an additive animation from where it was
/// (`MotionMove`), so the render server draws the in-between frames and a new target mid-motion
/// starts from what is on screen. The same target after pixel rounding moves nothing, so a relayout
/// for a title or a spinner never restarts a move (Chrome tab_container_impl.cc L1170-1175).
/// All animations of one change share `generation` and one transaction, so they start on one frame
/// and end together (`TabStripView.moveEnded`).
struct TabStripMove {
    let generation: Int
    /// The move of every tab, chip and band but a closing one.
    let motion: MotionMove
    /// A closing tab's move (`tabClose`), when it differs from `motion`.
    let closing: MotionMove?
    /// A reveal's scroll spring: it moves every layer alike and carries no closing tab.
    var isScroll = false
    /// The media time every animation of the change starts at (set on each, so `MotionPath` sums the
    /// moves in flight exactly; Core Animation would otherwise start them at the commit).
    let begin = CACurrentMediaTime()

    /// Key prefix of every animation a strip move adds (`cancel(_:)`).
    static let keyPrefix = "tab.move."
    /// Key suffix of the scroll part of a move (`cancelScroll(on:)`).
    static let scrollSuffix = ".scroll"

    private var key: String { "\(Self.keyPrefix)\(generation)." }

    /// Seconds a layer of this move takes to rest (`closing`: a closing tab's).
    func duration(closing: Bool) -> CFTimeInterval { (closing ? self.closing ?? motion : motion).duration }

    /// The model geometry of `root`, its sublayers (`depth` levels: a chip's pill content) and their
    /// masks, read before a change.
    struct Snapshot {
        fileprivate var layers: [(layer: CALayer, isMask: Bool, position: CGPoint, size: CGSize, opacity: Float)] = []
    }

    /// `depth` 0 and no `masks`: the root alone (a tab cell, whose inner parts and occlusion mask follow
    /// its path on their own: `TabCell.retimeInner`, `TabOcclusion`).
    static func snapshot(_ root: CALayer, depth: Int = 2, masks: Bool = true) -> Snapshot {
        var snapshot = Snapshot()
        func add(_ layer: CALayer, depth: Int) {
            snapshot.layers.append((layer, false, layer.position, layer.bounds.size, layer.opacity))
            if masks, let mask = layer.mask { snapshot.layers.append((mask, true, mask.position, mask.bounds.size, mask.opacity)) }
            guard depth > 0 else { return }
            for sublayer in layer.sublayers ?? [] { add(sublayer, depth: depth - 1) }
        }
        add(root, depth: depth)
        return snapshot
    }

    /// Adds an animation from each layer's value in `snapshot` to its model value now. Opacity moves
    /// only on the snapshot's root (a collapsing group's fade); a sublayer that shows or hides at
    /// another width does so at once. `scroll`: the part of the root's position change that the
    /// strip's scroll made; it moves under its own key, so a wheel ends it alone (`cancelScroll`).
    /// True when anything moved.
    @discardableResult
    /// `pinsEnd` (a root anchored at its leading edge): only the leading edge moves; the trailing edge
    /// is at its model at once (a group band whose end the dragged tab sets).
    func animate(from snapshot: Snapshot, closing isClosing: Bool = false, scroll: CGFloat = 0, pinsEnd: Bool = false) -> Bool {
        let move = isClosing ? closing ?? motion : motion
        var moved = false
        for (index, old) in snapshot.layers.enumerated() {
            let layer = old.layer
            // A sublayer the change removed draws nothing.
            guard index == 0 || old.isMask || layer.superlayer != nil else { continue }
            let scrolled = index == 0 ? scroll : 0
            let dp = CGPoint(x: old.position.x - layer.position.x - scrolled, y: old.position.y - layer.position.y)
            if abs(dp.x) > 0.01 || abs(dp.y) > 0.01 {
                add(move.additive("position", from: NSValue(point: dp), to: NSValue(point: .zero)), to: layer, as: "position")
                moved = true
            }
            if abs(scrolled) > 0.01 {
                addScroll(scrolled, to: layer)
                moved = true
            }
            let size = layer.bounds.size
            var ds = CGSize(width: old.size.width - size.width, height: old.size.height - size.height)
            // The start's move is taken off the width, its scroll part under the scroll key, so a wheel
            // that ends the scroll part ends both and the end stays put.
            if index == 0, pinsEnd {
                ds.width = -dp.x
                if abs(scrolled) > 0.01 {
                    add(motion.additive("bounds.size.width", from: NSNumber(value: Double(-scrolled)), to: NSNumber(value: 0)), to: layer, as: "size.scroll")
                }
            }
            if abs(ds.width) > 0.01 || abs(ds.height) > 0.01 {
                add(move.additive("bounds.size", from: NSValue(size: ds), to: NSValue(size: .zero)), to: layer, as: "size")
                moved = true
            }
            if index == 0, abs(old.opacity - layer.opacity) > 0.001 {
                add(move.additive("opacity", from: NSNumber(value: old.opacity - layer.opacity), to: NSNumber(value: 0)), to: layer, as: "opacity")
                moved = true
            }
        }
        return moved
    }

    /// Adds `animation` under this move's key `name`, starting at `begin`. The moves of earlier changes that
    /// are over come off first: their completion can trail by frames, and a layer retargeted quickly (a drag
    /// passing tabs) would otherwise carry one per change, which every path read sums (`MotionPath`).
    func add(_ animation: CAAnimation, to layer: CALayer, as name: String) {
        Self.removeEnded(on: layer, at: begin, keeping: generation)
        animation.beginTime = layer.convertTime(begin, from: nil)
        layer.add(animation, forKey: key + name)
    }

    /// Removes `layer`'s strip moves of other generations that ended by `now`: each is additive and ends at
    /// zero, so it adds nothing any more and nothing shown moves.
    static func removeEnded(on layer: CALayer, at now: CFTimeInterval, keeping generation: Int) {
        let own = "\(keyPrefix)\(generation)."
        for key in layer.animationKeys() ?? [] where key.hasPrefix(keyPrefix) && !key.hasPrefix(own) {
            guard let animation = layer.animation(forKey: key), (animation as? CAPropertyAnimation)?.isAdditive == true, animation.fillMode != .forwards,
                  animation.fillMode != .both else { continue }
            let duration = (animation as? CASpringAnimation).map { $0.duration > 0 ? $0.duration : $0.settlingDuration } ?? animation.duration
            let start = animation.beginTime > 0 ? layer.convertTime(animation.beginTime, to: nil) : now
            if start + duration / Double(max(animation.speed, .ulpOfOne)) <= now { layer.removeAnimation(forKey: key) }
        }
    }

    /// The scroll part of a move on the scrolling layer, whose bounds move every layer in it: `offset` (the view x
    /// its content showed minus the one now) is its bounds' x moving from the scroll before to the one now.
    func addScroll(boundsOf layer: CALayer, _ offset: CGFloat) {
        guard abs(offset) > 0.01 else { return }
        add(motion.additive("bounds.origin.x", from: NSNumber(value: Double(-offset)), to: NSNumber(value: 0)), to: layer, as: "scroll")
    }

    /// The scroll part of a move on `layer`: `offset` (the view x it showed minus the one now) to 0.
    func addScroll(_ offset: CGFloat, to layer: CALayer) {
        guard abs(offset) > 0.01 else { return }
        add(motion.additive("position.x", from: NSNumber(value: Double(offset)), to: NSNumber(value: 0)), to: layer, as: "scroll")
    }

    /// Whether a strip move runs on `layer` (its own, not its parts').
    static func isMoving(_ layer: CALayer) -> Bool {
        layer.animationKeys()?.contains { $0.hasPrefix(keyPrefix) } ?? false
    }

    /// Ends every strip move on `root`'s tree at once (a tab dropped back starts where the drop gap is).
    static func cancel(_ root: CALayer) {
        for old in snapshot(root).layers {
            for key in old.layer.animationKeys() ?? [] where key.hasPrefix(keyPrefix) { old.layer.removeAnimation(forKey: key) }
        }
    }

    /// Ends every strip move of `root`'s position at once: direct manipulation (a dragged tab sits
    /// exactly under the pointer; its width keeps moving).
    static func cancelPosition(_ root: CALayer) {
        for key in root.animationKeys() ?? [] where key.hasPrefix(keyPrefix) && (key.hasSuffix(".position") || key.hasSuffix(scrollSuffix)) {
            root.removeAnimation(forKey: key)
        }
    }

    /// Ends the scroll part of every move on `layers` at once (a wheel takes the scroll over).
    static func cancelScroll(on layers: [CALayer]) {
        for layer in layers {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(keyPrefix) && key.hasSuffix(scrollSuffix) { layer.removeAnimation(forKey: key) }
        }
    }
}
