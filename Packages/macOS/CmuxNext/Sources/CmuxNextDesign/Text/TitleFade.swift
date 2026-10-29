public import QuartzCore
import CmuxNextCompat
public import CmuxNextDesignTokens

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
    /// The motion gate of the title's owner (tabs or sidebar): its marquee
    /// and mask fades obey that category's switch.
    public let gate: MotionGate
    /// The motion policy (speed and Reduce Motion); tests pin it.
    public lazy var policy: () -> MotionPolicy = { [gate] in gate.policy }

    static let keyPath = "transform.translation.x"
    static let key = "marquee"

    /// - Parameters:
    ///   - textLayer: The title's text layer.
    ///   - gate: The owner's motion category (`Motion.tabs`, `Motion.sidebar`).
    public init(textLayer: CALayer, gate: MotionGate) {
        self.textLayer = textLayer
        self.gate = gate
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let clear = CGColor(gray: 0, alpha: 0)
        let opaque = CGColor(gray: 0, alpha: 1)
        mask.colors = [clear, opaque, opaque, clear, clear]
        mask.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull(), "transform": NSNull()]
    }

    /// Lays out the title. `frame` is its rest frame in the superlayer: the
    /// first glyph at `minX`, `width` equal to `geometry.span`. Call inside
    /// a transaction with actions disabled. `animated` fades the mask stops
    /// (Motion `hover`), for a tab's x appearing over the title's end.
    public func apply(_ geometry: TitleFadeGeometry, frame: CGRect, animated: Bool) {
        stopFollowing()
        let previous = self.geometry
        self.geometry = geometry
        var rest = frame
        rest.size.width = geometry.layerWidth(marquee: isMarqueeActive)
        textLayer.frame = rest
        guard geometry.isTruncated else {
            if isMarqueeActive { stopMarquee(animated: false) }
            guard animated, textLayer.mask === mask else {
                textLayer.mask = nil
                return
            }
            // The end comes back as the buttons over it fade out: the stops
            // ease open, then the mask goes.
            let (x, width) = geometry.maskFrame
            mask.frame = CGRect(x: x, y: 0, width: width, height: frame.height)
            let open = [0, geometry.leadingPadding / max(1, width), 1, 1, 1].map { NSNumber(value: Double($0)) }
            CATransaction.begin()
            CATransaction.setMainCompletion { [weak self] in self?.dropOpenMask() }
            gate.set(mask, "locations", to: open, fade: .hover)
            CATransaction.commit()
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
            gate.set(mask, "locations", to: locations, fade: .hover, from: from)
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

    /// The title's rest geometry and frame at one width of a moving row (`follow`).
    public struct Sample: Equatable {
        public var geometry: TitleFadeGeometry
        public var frame: CGRect

        public init(geometry: TitleFadeGeometry, frame: CGRect) {
            self.geometry = geometry
            self.frame = frame
        }
    }

    static let followKey = "follow."

    /// Shows the title at `samples` (one per media time in `times`, nil where it hides; the last is the
    /// target) as the row's width moves, the render server going from one to the next each frame, as
    /// a relayout per frame would. The text keeps one width the whole way (its glyphs never stretch or
    /// redraw); the mask carries the clip and the fade. Call inside a transaction with actions
    /// disabled, with no marquee running; `apply` ends it (the row at rest).
    /// `steps`: the samples after which the row changes form (`MotionPath.keyframes`).
    public func follow(_ samples: [Sample?], times: [CFTimeInterval], steps: Set<Int> = []) {
        stopFollowing()
        guard let target = samples.last(where: { $0 != nil }) ?? nil else { return }
        let shown = samples.compactMap(\.self)
        let width = shown.reduce(ceil(target.geometry.textWidth)) { max($0, $1.geometry.span) }
        // Where it hides, a sample holds the nearest shown one (the row hides the title then).
        var last = shown.first ?? target
        let filled = samples.map { sample -> Sample in
            if let sample { last = sample }
            return last
        }
        let height = target.frame.height
        func maskFrame(_ geometry: TitleFadeGeometry) -> CGRect {
            let (x, maskWidth) = geometry.maskFrame
            return CGRect(x: x, y: 0, width: maskWidth, height: height)
        }
        func locations(_ geometry: TitleFadeGeometry) -> [NSNumber] {
            let stops = geometry.isTruncated ? geometry.maskLocations : [0, geometry.leadingPadding / max(1, geometry.leadingPadding + geometry.span), 1, 1, 1]
            return stops.map { NSNumber(value: Double($0)) }
        }
        geometry = target.geometry
        textLayer.frame = CGRect(x: target.frame.minX, y: target.frame.minY, width: width, height: height)
        mask.frame = maskFrame(target.geometry)
        mask.removeAnimation(forKey: "locations")
        mask.locations = locations(target.geometry)
        textLayer.mask = mask
        let positions = filled.map { CGPoint(x: $0.frame.minX + width / 2, y: $0.frame.midY) }
        let masks = filled.map { maskFrame($0.geometry) }
        let stops = filled.map { locations($0.geometry) }
        func add(_ keyPath: String, _ values: [Any], to layer: CALayer, changes: Bool) {
            guard changes, let animation = MotionPath.keyframes(keyPath, values: values, times: times, on: layer, steps: steps) else { return }
            layer.add(animation, forKey: Self.followKey + keyPath)
        }
        add("position", positions.map { NSValue(point: $0) }, to: textLayer, changes: Set(positions.map(\.x)).count > 1 || Set(positions.map(\.y)).count > 1)
        add("position", masks.map { NSValue(point: CGPoint(x: $0.midX, y: $0.midY)) }, to: mask, changes: Set(masks.map(\.midX)).count > 1)
        add("bounds.size", masks.map { NSValue(size: $0.size) }, to: mask, changes: Set(masks.map(\.width)).count > 1)
        add("locations", stops, to: mask, changes: Set(stops).count > 1)
    }

    /// Ends a `follow` path (its keyframes come off; the model is the target already).
    public func stopFollowing() {
        for layer in [textLayer, mask] as [CALayer] {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.followKey) { layer.removeAnimation(forKey: key) }
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
        guard let text = gate.marqueeAnimation(keyPath: Self.keyPath, travel: travel, sign: -1,
                                                 now: textLayer.convertTime(now, from: nil), policy: policy),
              let counter = gate.marqueeAnimation(keyPath: Self.keyPath, travel: travel, sign: 1,
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
        CATransaction.setMainCompletion { [weak self] in self?.restoreWidth() }
        gate.set(textLayer, Self.keyPath, to: CGFloat(0), spring: .disappear, from: shown)
        gate.set(mask, Self.keyPath, to: CGFloat(0), spring: .disappear, from: -shown)
        CATransaction.commit()
    }

    /// Drops the mask an unclipped title eased open, unless it clips again.
    private func dropOpenMask() {
        guard geometry?.isTruncated == false, textLayer.mask === mask else { return }
        textLayer.mask = nil
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
