public import QuartzCore
import CmuxNextCompat

/// Holes in the chrome's shade under each selected folder tab (design/selected-is-foreground.md).
///
/// A folder tab is the foreground: the content's own surface, the same as the content it opens. Over
/// an opaque window its fill alone covers the shade, but over a see-through one (a translucent theme,
/// an image background) the shade would still darken what shows through the tab, so the tab would read
/// darker than its content. The shade leaves a hole under each folder instead, and the tab's fill over
/// the hole is exactly the content's fill over the backdrop.
///
/// A selection change fades the holes (`MotionFade.crossfade`, the same 80 ms as the tab's fill): the
/// old tab's hole closes as its folder fades out and the new one opens as its folder fades in, so the
/// shade, the shape and the color move together. A geometry change (a resize, a scroll) moves a hole at
/// once. The holes are the shade layer's mask: an opaque base with every hole cut out, and over it one
/// patch per hole whose opacity is the hole's closedness (0 open, 1 closed).
@MainActor
public final class ChromeShadeHoles {
    /// The shade layer's mask (`CALayer.mask`): give it the shade's bounds (``layout(bounds:)``).
    public let mask = CALayer()
    private let base = CAShapeLayer()
    private var open: [ObjectIdentifier: (path: CGPath, patch: CAShapeLayer)] = [:]
    /// Holes closing after a selection change: their patches fade in, then go.
    private var closing: [(path: CGPath, patch: CAShapeLayer)] = []

    public init() {
        let still: [String: any CAAction] = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        mask.actions = still
        base.actions = still
        base.fillColor = CGColor(gray: 0, alpha: 1)
        mask.addSublayer(base)
    }

    /// No hole is open or closing: the mask can stay off the shade.
    public var isEmpty: Bool { open.isEmpty && closing.isEmpty }

    /// The shade's bounds changed: the mask covers them.
    public func layout(bounds: CGRect) {
        guard mask.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        base.frame = mask.bounds
        rebuildBase()
        CATransaction.commit()
    }

    /// Sets the hole `key` (one per tab strip) to `path` in the mask's coordinates; nil closes it.
    /// `animated`: a selection change, faded with the tabs; else at once.
    public func set(_ key: ObjectIdentifier, path: CGPath?, animated: Bool) {
        let old = open[key]
        if let old, let path, old.path == path { return }
        if old == nil, path == nil { return }
        open[key] = nil
        if let old {
            if animated {
                closing.append(old)
                CATransaction.begin()
                CATransaction.setMainCompletion { [weak self, patch = old.patch] in self?.finishClosing(patch) }
                Motion.tabs.set(old.patch, "opacity", to: Float(1), fade: .crossfade)
                CATransaction.commit()
            } else {
                old.patch.removeFromSuperlayer()
            }
        }
        if let path {
            let patch = CAShapeLayer()
            patch.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
            patch.frame = mask.bounds
            patch.path = path
            patch.fillColor = CGColor(gray: 0, alpha: 1)
            patch.opacity = animated ? 1 : 0
            mask.addSublayer(patch)
            open[key] = (path, patch)
            if animated { Motion.tabs.set(patch, "opacity", to: Float(0), fade: .crossfade) }
        }
        rebuildBase()
    }

    private func finishClosing(_ patch: CAShapeLayer) {
        guard let index = closing.firstIndex(where: { $0.patch === patch }) else { return }
        closing.remove(at: index)
        patch.removeFromSuperlayer()
        rebuildBase()
    }

    /// The base: the mask's bounds less every open and closing hole.
    private func rebuildBase() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let paths = open.values.map(\.path) + closing.map(\.path)
        let full = CGPath(rect: mask.bounds, transform: nil)
        guard let first = paths.first else {
            base.path = full
            return
        }
        let holes = paths.dropFirst().reduce(first) { $0.union($1) }
        base.path = full.subtracting(holes)
        for patch in open.values.map(\.patch) + closing.map(\.patch) where patch.frame != mask.bounds { patch.frame = mask.bounds }
    }
}

extension CALayer {
    /// `path`, in `source`'s coordinates, in this layer's (both in one layer tree): the affine map the
    /// layers' geometry gives, a flip between flipped and unflipped views included.
    public func converted(_ path: CGPath, from source: CALayer) -> CGPath {
        let o = convert(CGPoint.zero, from: source)
        let x = convert(CGPoint(x: 1, y: 0), from: source)
        let y = convert(CGPoint(x: 0, y: 1), from: source)
        var map = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: o.x, ty: o.y)
        return path.copy(using: &map) ?? path
    }
}
