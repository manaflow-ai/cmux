public import QuartzCore

/// Fades a clipped single-line title and runs its hover marquee.
///
/// It owns one gradient mask on the title layer, present only while the
/// title is clipped (idle titles cost no extra layer). The marquee is one
/// Core Animation keyframe pass on the title's `transform.translation.x`
/// with the same pass inverted on the mask, so the text moves under a mask
/// that stays put. Its start delay is the animation's `beginTime`, so no
/// timer, display link or polling runs in the app, and nothing runs at all
/// once the pass ends. Reduce Motion and `ui.animationSpeed` "off" never
/// start one (`MotionPolicy.marquee(travel:)`).
public final class TitleFade {
    public let textLayer: CALayer
    private let mask = CAGradientLayer()
    public private(set) var geometry: TitleFadeGeometry?
    /// A marquee started and the pointer has not left since. Stays true
    /// after its single pass ends, until `stopMarquee()`.
    public private(set) var isMarqueeActive = false
    /// The motion policy (speed and Reduce Motion); tests pin it.
    public var policy: () -> MotionPolicy = { Motion.policy }

    static let keyPath = "transform.translation.x"
    static let key = "marquee"

    public init(textLayer: CALayer) {
        self.textLayer = textLayer
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let clear = CGColor(gray: 0, alpha: 0)
        let opaque = CGColor(gray: 0, alpha: 1)
        mask.colors = [clear, opaque, opaque, clear, clear]
        mask.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull(), "transform": NSNull()]
    }

    /// The gradient mask while the title is clipped (tests and layer budgets).
    public var activeMask: CAGradientLayer? { textLayer.mask === mask ? mask : nil }

    /// Lays out the title. `frame` is its rest frame in the superlayer: the
    /// first glyph at `minX`, `width` equal to `geometry.span`. Call inside
    /// a transaction with actions disabled. `animated` fades the mask stops
    /// (Motion `hover`), for a tab's x appearing over the title's end.
    public func apply(_ geometry: TitleFadeGeometry, frame: CGRect, animated: Bool) {
        let previous = self.geometry
        self.geometry = geometry
        var rest = frame
        rest.size.width = geometry.layerWidth(marquee: isMarqueeActive)
        textLayer.frame = rest
        guard geometry.isTruncated else {
            if isMarqueeActive { stopMarquee(animated: false) }
            textLayer.mask = nil
            return
        }
        let (x, width) = geometry.maskFrame
        mask.frame = CGRect(x: x, y: 0, width: width, height: frame.height)
        let wasMasked = textLayer.mask === mask
        textLayer.mask = mask
        let locations = geometry.maskLocations.map { NSNumber(value: Double($0)) }
        if animated, (mask.locations ?? []) != locations {
            // A title that was not clipped starts fully visible.
            let from: [NSNumber]? = wasMasked ? nil : [0, locations[1], 1, 1, 1]
            Motion.set(mask, "locations", to: locations, fade: .hover, from: from)
        } else {
            mask.removeAnimation(forKey: "locations")
            mask.locations = locations
        }
        if isMarqueeActive, previous?.marqueeTravel != geometry.marqueeTravel {
            // The clip changed under a running pass: start over from rest.
            stopMarquee(animated: false)
            startMarquee()
        }
    }

    /// Starts one marquee pass after the hover delay. Returns false when
    /// nothing is clipped, when motion is reduced or off, or when one is
    /// already active.
    @discardableResult
    public func startMarquee() -> Bool {
        guard !isMarqueeActive, let geometry, geometry.isTruncated, textLayer.mask === mask else { return false }
        let travel = geometry.marqueeTravel
        let now = CACurrentMediaTime()
        let policy = policy()
        guard let text = Motion.marqueeAnimation(keyPath: Self.keyPath, travel: travel, sign: -1,
                                                 now: textLayer.convertTime(now, from: nil), policy: policy),
              let counter = Motion.marqueeAnimation(keyPath: Self.keyPath, travel: travel, sign: 1,
                                                    now: mask.convertTime(now, from: nil), policy: policy)
        else { return false }
        isMarqueeActive = true
        setWidth(geometry.layerWidth(marquee: true))
        textLayer.add(text, forKey: Self.key)
        mask.add(counter, forKey: Self.key)
        return true
    }

    /// Stops the marquee at once. A title caught mid-scroll springs back
    /// from where it is on screen (Motion `disappear`) unless `animated` is
    /// false or movement does not animate.
    public func stopMarquee(animated: Bool = true) {
        guard isMarqueeActive else { return }
        isMarqueeActive = false
        let shown = (textLayer.presentation()?.value(forKeyPath: Self.keyPath) as? CGFloat) ?? 0
        textLayer.removeAnimation(forKey: Self.key)
        mask.removeAnimation(forKey: Self.key)
        guard animated, abs(shown) > 0.5, policy().animatesMovement else {
            textLayer.removeAnimation(forKey: Self.keyPath)
            mask.removeAnimation(forKey: Self.keyPath)
            return restoreWidth()
        }
        CATransaction.begin()
        // The title keeps its full width until it is back at rest, so its
        // end is never cut while it slides back.
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.restoreWidth() } }
        Motion.set(textLayer, Self.keyPath, to: CGFloat(0), spring: .disappear, from: shown)
        Motion.set(mask, Self.keyPath, to: CGFloat(0), spring: .disappear, from: -shown)
        CATransaction.commit()
    }

    private func restoreWidth() {
        guard !isMarqueeActive, let geometry else { return }
        setWidth(geometry.layerWidth(marquee: false))
    }

    private func setWidth(_ width: CGFloat) {
        guard textLayer.bounds.width != width else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var frame = textLayer.frame
        frame.size.width = width
        textLayer.frame = frame
        CATransaction.commit()
    }
}
