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

    /// Key prefix of every animation a strip move adds (`cancel(_:)`).
    static let keyPrefix = "tab.move."

    private var key: String { "\(Self.keyPrefix)\(generation)." }

    /// Seconds a layer of this move takes to rest (`closing`: a closing tab's).
    func duration(closing: Bool) -> CFTimeInterval { (closing ? self.closing ?? motion : motion).duration }

    /// The model geometry of `root`, its sublayers (two levels: a chip's pill content) and their
    /// masks, read before a change.
    struct Snapshot {
        fileprivate var layers: [(layer: CALayer, isMask: Bool, position: CGPoint, size: CGSize, opacity: Float)] = []
    }

    static func snapshot(_ root: CALayer) -> Snapshot {
        var snapshot = Snapshot()
        func add(_ layer: CALayer, depth: Int) {
            snapshot.layers.append((layer, false, layer.position, layer.bounds.size, layer.opacity))
            if let mask = layer.mask { snapshot.layers.append((mask, true, mask.position, mask.bounds.size, mask.opacity)) }
            guard depth > 0 else { return }
            for sublayer in layer.sublayers ?? [] { add(sublayer, depth: depth - 1) }
        }
        add(root, depth: 2)
        return snapshot
    }

    /// Adds an animation from each layer's value in `snapshot` to its model value now. Opacity moves
    /// only on the snapshot's root (a collapsing group's fade); a sublayer that shows or hides at
    /// another width does so at once, as it did when the strip stepped every frame. True when
    /// anything moved.
    @discardableResult
    func animate(from snapshot: Snapshot, closing isClosing: Bool = false) -> Bool {
        let move = isClosing ? closing ?? motion : motion
        var moved = false
        for (index, old) in snapshot.layers.enumerated() {
            let layer = old.layer
            // A sublayer the change removed draws nothing.
            guard index == 0 || old.isMask || layer.superlayer != nil else { continue }
            let dp = CGPoint(x: old.position.x - layer.position.x, y: old.position.y - layer.position.y)
            if abs(dp.x) > 0.01 || abs(dp.y) > 0.01 {
                layer.add(move.additive("position", from: NSValue(point: dp), to: NSValue(point: .zero)), forKey: key + "position")
                moved = true
            }
            let size = layer.bounds.size
            let ds = CGSize(width: old.size.width - size.width, height: old.size.height - size.height)
            if abs(ds.width) > 0.01 || abs(ds.height) > 0.01 {
                layer.add(move.additive("bounds.size", from: NSValue(size: ds), to: NSValue(size: .zero)), forKey: key + "size")
                moved = true
            }
            if index == 0, abs(old.opacity - layer.opacity) > 0.001 {
                layer.add(move.additive("opacity", from: NSNumber(value: old.opacity - layer.opacity), to: NSNumber(value: 0)), forKey: key + "opacity")
                moved = true
            }
        }
        return moved
    }

    /// Adds `animation` (a keyframe path) under this move's key.
    func add(_ animation: CAAnimation, to layer: CALayer, as name: String) {
        layer.add(animation, forKey: key + name)
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
        for key in root.animationKeys() ?? [] where key.hasPrefix(keyPrefix) && key.hasSuffix(".position") { root.removeAnimation(forKey: key) }
    }

    /// Ends the moves of `generations` on `layers` at once (a wheel takes over a reveal's scroll).
    static func cancel(_ generations: Set<Int>, on layers: [CALayer]) {
        let prefixes = generations.map { "\(keyPrefix)\($0)." }
        for layer in layers {
            for key in layer.animationKeys() ?? [] where prefixes.contains(where: key.hasPrefix) { layer.removeAnimation(forKey: key) }
        }
    }
}
