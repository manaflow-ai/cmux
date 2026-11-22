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
    /// A layer this change moves while an earlier move still runs restarts from what it shows
    /// (`takeOver`): one curve from there to the new target, never a second curve stacked on the first.
    /// True when anything moved.
    @discardableResult
    /// `pinsEnd` (a root anchored at its leading edge): only the leading edge moves; the trailing edge
    /// is at its model at once (a group band whose end the dragged tab sets).
    /// `restarts`: the root restarts its moves in flight on this change's curve even when its target is the same
    /// (`TabStripView.applyFrames`: every tab still moving joins the change, so neighbours stay edge to edge).
    func animate(from snapshot: Snapshot, closing isClosing: Bool = false, scroll: CGFloat = 0, pinsEnd: Bool = false,
                 restarts: Bool = false) -> Bool {
        let move = isClosing ? closing ?? motion : motion
        var moved = false
        for (index, old) in snapshot.layers.enumerated() {
            let layer = old.layer
            // A sublayer the change removed draws nothing.
            guard index == 0 || old.isMask || layer.superlayer != nil else { continue }
            let scrolled = index == 0 ? scroll : 0
            var dp = CGPoint(x: old.position.x - layer.position.x - scrolled, y: old.position.y - layer.position.y)
            let size = layer.bounds.size
            var ds = CGSize(width: old.size.width - size.width, height: old.size.height - size.height)
            // A new target: the position and size moves in flight end here, and the new move starts from what
            // they still owed (both together, so the layer's edges share one curve).
            if (index == 0 && restarts) || abs(dp.x) > 0.01 || abs(dp.y) > 0.01 || (!pinsEnd && (abs(ds.width) > 0.01 || abs(ds.height) > 0.01)) {
                let owed = takeOver(layer, "position", as: "position")
                dp.x += owed.x
                dp.y += owed.y
                let owedSize = takeOver(layer, "bounds.size", as: "size")
                ds.width += owedSize.x
                ds.height += owedSize.y
            }
            if abs(dp.x) > 0.01 || abs(dp.y) > 0.01 {
                add(move.additive("position", from: NSValue(point: dp), to: NSValue(point: .zero)), to: layer, as: "position")
                moved = true
            }
            if abs(scrolled) > 0.01 {
                addScroll(scrolled, to: layer)
                moved = true
            }
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
                let owed = takeOver(layer, "opacity", as: "opacity").x
                add(move.additive("opacity", from: NSNumber(value: Double(old.opacity - layer.opacity) + Double(owed)), to: NSNumber(value: 0)),
                    to: layer, as: "opacity")
                moved = true
            }
        }
        return moved
    }

    /// Moves `layer`'s position from `offset` (where it was minus where it is now) to its model under `name`,
    /// restarting from what an earlier move of `name` still shows (`takeOver`). True when it moves.
    @discardableResult
    func move(_ layer: CALayer, position offset: CGPoint, as name: String) -> Bool {
        let owed = takeOver(layer, "position", as: name)
        let delta = CGPoint(x: offset.x + owed.x, y: offset.y + owed.y)
        guard abs(delta.x) > 0.01 || abs(delta.y) > 0.01 else { return false }
        add(motion.additive("position", from: NSValue(point: delta), to: NSValue(point: .zero)), to: layer, as: name)
        return true
    }

    /// Ends the earlier strip moves of `name` on `layer` (not their scroll parts, which a wheel owns) and returns
    /// what they still added to `keyPath` at this move's begin. A new target starts from the value on screen with
    /// no velocity (motion-first-principles-DESIGN.md principle 5; Chrome's `BoundsAnimator::AnimateViewTo`): two
    /// ease-outs stacked with opposite travel pass the new target and come back, one from the value on screen never
    /// does. A scroll move takes nothing over: it only adds its own part.
    func takeOver(_ layer: CALayer, _ keyPath: String, as name: String) -> CGPoint {
        guard !isScroll else { return .zero }
        let suffix = "." + name
        let earlier = Set((layer.animationKeys() ?? []).filter { $0.hasPrefix(Self.keyPrefix) && $0.hasSuffix(suffix) && !$0.hasPrefix(key) })
        guard !earlier.isEmpty else { return .zero }
        let owed = MotionPath.offset(of: layer, keyPath, at: begin) { earlier.contains($0) }
        for earlierKey in earlier { layer.removeAnimation(forKey: earlierKey) }
        return owed
    }

    /// Adds `animation` under this move's key `name`, starting at `begin`.
    func add(_ animation: CAAnimation, to layer: CALayer, as name: String) {
        animation.beginTime = layer.convertTime(begin, from: nil)
        layer.add(animation, forKey: key + name)
    }

    /// The scroll part of a move on `layer`: `offset` (the view x it showed minus the one now) to 0.
    func addScroll(_ offset: CGFloat, to layer: CALayer) {
        guard abs(offset) > 0.01 else { return }
        add(motion.additive("position.x", from: NSNumber(value: Double(offset)), to: NSNumber(value: 0)), to: layer, as: "scroll")
    }

    /// The frame `layer` shows at media time `time`: its model plus every animation on it, evaluated as the render
    /// server does (`MotionPath`). Not `presentation()`: that is the state of the last commit, so it leaves out every
    /// move added since (two opens in one main-thread turn, a script's burst, a busy main thread) and is nil for a
    /// layer made in this turn, where it fell back to the model, the move's end instead of where the layer shows.
    static func shownFrame(_ layer: CALayer, at time: CFTimeInterval = CACurrentMediaTime()) -> CGRect {
        let size = MotionPath(layer, "bounds.size", now: time).value(at: time)
        let position = MotionPath(layer, "position", now: time).value(at: time)
        let width = max(0, size.x), height = max(0, size.y)
        return CGRect(x: position.x - layer.anchorPoint.x * width, y: position.y - layer.anchorPoint.y * height, width: width, height: height)
    }

    /// Whether a strip move other than a scroll part still runs on `layer` (a scroll part ends with its wheel).
    static func isMoving(_ layer: CALayer) -> Bool {
        (layer.animationKeys() ?? []).contains { $0.hasPrefix(keyPrefix) && !$0.hasSuffix(scrollSuffix) }
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
