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
/// shade, the shape and the color move together. A folder moving with its tab (a reflow, an open, a
/// close: ``FolderMotion``) moves its hole along the folder's own samples; any other geometry change
/// (a resize, a scroll) moves a hole at once. The holes are the shade layer's mask: an opaque base with every hole cut out, and over it one
/// patch per hole whose opacity is the hole's closedness (0 open, 1 closed).
/// A folder tab's outline along a move in flight (its tab's width or slot changing,
/// `TabCell+InnerPath`, `TabStripMove`): `paths[i]` is the outline at media time `times[i]`, the last
/// the model's. The shade's hole under the folder plays the same samples, so the hole, the folder's
/// shape and its fill move together frame by frame (design/selected-is-foreground.md, motion).
public struct FolderMotion {
    public let times: [CFTimeInterval]
    public let paths: [CGPath]

    public init(times: [CFTimeInterval], paths: [CGPath]) {
        self.times = times
        self.paths = paths
    }

    /// The same samples with every path mapped (into another layer's coordinates).
    public func map(_ transform: (CGPath) -> CGPath) -> FolderMotion { FolderMotion(times: times, paths: paths.map(transform)) }

    /// Whether any sample is still ahead of `now`.
    public func moves(after now: CFTimeInterval) -> Bool { (times.last ?? 0) > now }

    /// The outline shown at `time`: the latest sample at or before it (samples are one display frame apart).
    public func path(at time: CFTimeInterval) -> CGPath? {
        guard !paths.isEmpty, paths.count == times.count else { return nil }
        let index = times.lastIndex { $0 <= time } ?? 0
        return paths[index]
    }
}

@MainActor
public final class ChromeShadeHoles {
    /// The shade layer's mask (`CALayer.mask`): give it the shade's bounds (``layout(bounds:)``).
    public let mask = CALayer()
    private let base = CAShapeLayer()
    private var open: [ObjectIdentifier: (path: CGPath, patch: CAShapeLayer)] = [:]
    /// The holes whose folder is moving, keyed like `open`: the base plays their samples.
    private var moving: [ObjectIdentifier: FolderMotion] = [:]
    static let motionKey = "folder.hole.motion"
    /// Holes closing after a selection change: their patches fade in, then go.
    private var closing: [(path: CGPath, patch: CAShapeLayer)] = []

    public init() {
        let still: [String: any CAAction] = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        mask.actions = still
        base.actions = still
        base.fillColor = CGColor(gray: 0, alpha: 1) // colour-allow: a mask, only its alpha counts
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
    /// `animated`: a selection change, faded with the tabs; else at once, or, with `motion` (the folder
    /// moving with its tab, in the mask's coordinates), along the folder's own samples.
    public func set(_ key: ObjectIdentifier, path: CGPath?, animated: Bool, motion: FolderMotion? = nil) {
        let old = open[key]
        let follows = path != nil && !animated ? motion.flatMap { $0.moves(after: CACurrentMediaTime()) ? $0 : nil } : nil
        if let old, let path, old.path == path {
            if let follows {
                moving[key] = follows
                rebuildBase()
            }
            return
        }
        moving[key] = follows
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
            patch.fillColor = CGColor(gray: 0, alpha: 1) // colour-allow: a mask, only its alpha counts
            patch.opacity = animated ? 1 : 0
            mask.addSublayer(patch)
            open[key] = (path, patch)
            if animated { Motion.tabs.set(patch, "opacity", to: Float(0), fade: .crossfade) }
        }
        rebuildBase()
    }

    /// The base along the moving folders' samples (``FolderMotion``): at each sample time, the mask less
    /// every hole as it shows then, so a hole moves with its folder instead of jumping to the end. O(samples)
    /// boolean ops once per move start, nothing per frame; no move in flight takes the animation off.
    private func followMotion(full: CGPath) {
        base.removeAnimation(forKey: Self.motionKey)
        let now = CACurrentMediaTime()
        moving = moving.filter { open[$0.key] != nil && $0.value.moves(after: now) }
        guard let end = moving.values.compactMap(\.times.last).max() else { return }
        let times = [now] + Set(moving.values.flatMap(\.times)).filter { $0 > now && $0 <= end }.sorted()
        let values: [CGPath] = times.map { time in
            let shown = open.map { key, hole in moving[key]?.path(at: time) ?? hole.path } + closing.map(\.path)
            guard let first = shown.first else { return full }
            return full.subtracting(shown.dropFirst().reduce(first) { $0.union($1) })
        }
        if let animation = MotionPath.keyframes("path", values: values, times: times, on: base) {
            base.add(animation, forKey: Self.motionKey)
        }
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
        followMotion(full: full)
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
