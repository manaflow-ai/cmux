public import QuartzCore

/// The rounded rect a layer's shadow is cast from, in the layer's own coordinates.
///
/// A layer with a shadow and no `shadowPath` makes Core Animation render the layer and its sublayers
/// offscreen whenever it draws, to find the alpha the shadow follows. Chrome never derives a shadow from
/// content: `ui/compositor_extra/shadow.cc` draws it from a nine-patch of the rounded rect
/// (`ui/gfx/shadow_util.cc`) and rebuilds it only when `SetContentBounds` gets new bounds.
/// ``CALayer/cast(shadowPath:)`` does the same with `shadowPath`.
public nonisolated struct ShadowOutline: Equatable, Sendable {
    /// The outline's size: the layer's bounds size.
    public let size: CGSize
    /// The corner radius, at most half the shorter side (a capsule or a circle at the limit).
    public let cornerRadius: CGFloat

    public init(size: CGSize, cornerRadius: CGFloat) {
        let size = CGSize(width: max(0, size.width), height: max(0, size.height))
        self.size = size
        self.cornerRadius = max(0, min(cornerRadius, size.width / 2, size.height / 2))
    }

    /// The values the path is made of: equal keys build equal paths.
    var key: [CGFloat] { [size.width, size.height, cornerRadius] }

    /// The outline as a path from the origin.
    public var path: CGPath {
        CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: cornerRadius, cornerHeight: cornerRadius,
               transform: nil)
    }

    /// The band a `CALayer` border `width` wide draws inside this outline (its outer corner is the
    /// outline's, its inner one `width` less), as one path that fills with the non-zero rule
    /// `shadowPath` uses: the inner outline runs the other way. Nil when the band is empty or fills
    /// the whole outline.
    public func band(width: CGFloat) -> CGPath? {
        guard width > 0, size.width > width * 2, size.height > width * 2 else { return nil }
        let inner = ShadowOutline(size: CGSize(width: size.width - width * 2, height: size.height - width * 2),
                                  cornerRadius: cornerRadius - width)
        let band = CGMutablePath()
        band.addPath(path)
        // Mirrored about its own vertical center: the same shape, wound the other way.
        band.addPath(inner.path, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width + inner.size.width, ty: width))
        return band
    }

    /// The `shadowOpacity` that casts as strongly from a path as `opacity` cast from content filled
    /// with `fill`: a content shadow is as opaque as the content, a path shadow is opaque everywhere
    /// in the path. No fill casts nothing, as no content did.
    public static func opacity(_ opacity: CGFloat, under fill: CGColor?) -> Float {
        Float(opacity * (fill?.alpha ?? 0))
    }
}

extension CALayer {
    /// The values a layer's `shadowPath` was built from, kept on the layer as a typed associated object
    /// (no key-value coding by a string key, which raises for a key the object does not take).
    private static let shadowPathInputs = ObjectAssociation<[CGFloat]>()
    /// The keyframes of a shadow path that follows the layer's moving size.
    public static let shadowPathFollowKey = "cmux.shadowPath.follow"

    /// Casts the layer's shadow from `outline` (``cast(shadowPathFor:_:)``).
    public func cast(shadowPath outline: ShadowOutline) {
        cast(shadowPathFor: outline.key) { outline.path }
    }

    /// Casts the layer's shadow from the path `build` makes, with no implicit animation. `key` is the
    /// values the path is made of: the path is built and set only when they changed, so a layout that
    /// keeps them costs one comparison. A nil path casts nothing (an empty path, never a shadow derived
    /// from content). Set the layer's `shadowPath` only through here or ``castFromContent()``.
    public func cast(shadowPathFor key: [CGFloat], _ build: () -> CGPath?) {
        if shadowPath != nil, Self.shadowPathInputs.value(on: self) == key { return }
        let path: CGPath = build() ?? CGMutablePath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowPath = path
        Self.shadowPathInputs.set(key, on: self)
        CATransaction.commit()
    }

    /// Makes the shadow path follow the layer's size while animations move it: keyframes of
    /// `outline` at every frame from `now` to the end of every animation on `bounds.size`
    /// (``MotionPath``, the values the render server shows, springs and retargets included), so a
    /// springing layer keeps a path and never falls back to a shadow derived from content. Replaces
    /// the keyframes an earlier call added; adds none when nothing moves the size or the layer shows
    /// no shadow (``castsShadow(after:)``). The model path stays the one for the model size.
    public func followShadowPath(now: CFTimeInterval = CACurrentMediaTime(), _ outline: (CGSize) -> CGPath?) {
        removeAnimation(forKey: Self.shadowPathFollowKey)
        guard castsShadow(after: now) else { return }
        let size = MotionPath(self, "bounds.size", now: now)
        guard size.isExact, let end = size.end, end > now + 0.001 else { return }
        let times = MotionPath.times(from: now, to: end, count: MotionPath.sampleCount(seconds: end - now))
        let paths = times.indices.map { index -> CGPath in
            let value = index == times.count - 1 ? CGPoint(x: bounds.width, y: bounds.height) : size.value(at: times[index])
            let path: CGPath = outline(CGSize(width: max(0, value.x), height: max(0, value.y))) ?? CGMutablePath()
            return path
        }
        // Core Animation interpolates two paths only when they have the same elements; a size that
        // clamps a corner away changes them, and those frames hold instead.
        let counts = Set(paths.map(Self.elementCount))
        guard let animation = MotionPath.keyframes("shadowPath", values: paths, times: times, on: self, discrete: counts.count > 1) else { return }
        add(animation, forKey: Self.shadowPathFollowKey)
    }

    /// Whether the layer shows a shadow after media time `now`: its model strength is above 0, or an
    /// animation of the strength still runs (a lift that ends fades its shadow out from a model of 0).
    public func castsShadow(after now: CFTimeInterval) -> Bool {
        if shadowOpacity > 0 { return true }
        return (animationKeys() ?? []).contains { key in
            guard let fade = animation(forKey: key) as? CAPropertyAnimation, fade.keyPath == "shadowOpacity" else { return false }
            let begin = fade.beginTime > 0 ? convertTime(fade.beginTime, to: nil) : now
            return begin + fade.duration / Double(max(fade.speed, .ulpOfOne)) > now
        }
    }

    /// Casts the layer's shadow from its content's alpha again: no `shadowPath`, no follow. Only for a
    /// layer whose shape is its content, marked `// shadow: alpha-derived <why>` where it is called.
    public func castFromContent() {
        stopFollowingShadowPath()
        guard shadowPath != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowPath = nil
        Self.shadowPathInputs.set(nil, on: self)
        CATransaction.commit()
    }

    /// Ends ``followShadowPath(now:_:)``'s keyframes: the model path shows.
    public func stopFollowingShadowPath() {
        removeAnimation(forKey: Self.shadowPathFollowKey)
    }

    private static func elementCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        return count
    }
}
