import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CoreImage
import CoreImage.CIFilterBuiltins

/// The SDK motion props every node accepts (`cmux-app-host/js/ABI.md` "Motion"), drawn with Core
/// Animation so nothing runs per frame on the main thread:
///
/// - `animation`: a change of an animatable prop (opacity, scale, offset, rotation, blur, glow,
///   colors, a shape's trim, a frame's size, a ProgressView's value) springs or eases from what is
///   on screen to the new value. Numbers and transforms animate additively, so a change in flight
///   keeps its motion and the next one adds to it; colors and outlines start from the presentation
///   value.
/// - `loop`: a repeating animation on the layer, additive on its model value (``SceneLoop``).
/// - `transition`: an enter animation the first time the node is laid out in a window, and an
///   exit animation when it is removed; the view stays in its parent until the exit ends. In a
///   widget tile only, and only `pop` (``playsSDKTransition``): the widget host plays the others.
/// - `blur`, `glow`, `gradient`: a Gaussian content filter, a zero-offset colored shadow and a
///   gradient layer.
///
/// All of it asks ``Motion/appScenes``: under Reduce Motion or speed off, changes and transitions
/// apply at once and loops stop; `glow`, `gradient` and `blur` still draw.
extension AppSceneNodeNSView {
    // MARK: Writes that animate during a prop change

    /// Writes model values with no implicit action.
    func withoutActions(_ write: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        write()
        CATransaction.commit()
    }

    /// Adds an additive animation from `from` (the old value less the new) to `zero`, when a prop
    /// change with an `animation` is being applied.
    func animateAdditive(_ layer: CALayer, _ keyPath: String, from: Any, zero: Any) {
        guard let motion = changeMotion, Motion.canAnimate(in: self),
              let animation = Motion.appScenes.sceneAnimation(motion, keyPath, from: from, to: zero, additive: true, in: window) else { return }
        additiveSerial &+= 1
        layer.add(animation, forKey: "scene.\(keyPath).\(additiveSerial)")
    }

    /// Sets a number (`shadowRadius`, `strokeEnd` ...; `keyPath` names `property` for Core
    /// Animation), animating additively from the old one.
    func animateNumber<L: CALayer, V: BinaryFloatingPoint>(_ layer: L, _ property: ReferenceWritableKeyPath<L, V>, _ keyPath: String, _ value: V) {
        let old = layer[keyPath: property]
        guard old != value else { return }
        withoutActions { layer[keyPath: property] = value }
        animateAdditive(layer, keyPath, from: NSNumber(value: Double(old - value)), zero: NSNumber(value: 0))
    }

    /// Sets a value that does not add (an outline), animating from the one on screen.
    func animateValue<L: CALayer, V: Equatable>(_ layer: L, _ property: ReferenceWritableKeyPath<L, V?>, _ keyPath: String, _ value: V?) {
        let old = layer[keyPath: property]
        guard old != value else { return }
        let shown = layer.presentation()?[keyPath: property] ?? old
        withoutActions { layer[keyPath: property] = value }
        play(layer, keyPath, from: shown, to: value)
    }

    /// A gradient's colors, animating from the ones on screen.
    func animateColors(_ layer: CAGradientLayer, _ colors: [CGColor]) {
        let old = layer.colors as? [CGColor]
        guard old != colors else { return }
        let shown = layer.presentation()?.colors ?? layer.colors
        withoutActions { layer.colors = colors }
        play(layer, "colors", from: shown, to: colors)
    }

    /// Adds the change's animation of `keyPath` from `from` to `to`, or drops one in flight when the
    /// change applies at once.
    private func play(_ layer: CALayer, _ keyPath: String, from: Any?, to: Any?) {
        guard let motion = changeMotion, let from, let to, Motion.canAnimate(in: self),
              let animation = Motion.appScenes.sceneAnimation(motion, keyPath, from: from, to: to, in: window) else {
            layer.removeAnimation(forKey: "scene.\(keyPath)")
            return
        }
        layer.add(animation, forKey: "scene.\(keyPath)")
    }

    /// Sets a color (`keyPath` names `property` for Core Animation), animating from the one on
    /// screen (from or to clear when one side has none).
    func animateColor<L: CALayer>(_ layer: L, _ property: ReferenceWritableKeyPath<L, CGColor?>, _ keyPath: String, _ color: CGColor?) {
        let old = layer[keyPath: property]
        guard old != color else { return }
        let shown = layer.presentation()?[keyPath: property] ?? old
        withoutActions { layer[keyPath: property] = color }
        play(layer, keyPath, from: shown ?? color?.copy(alpha: 0), to: color ?? shown?.copy(alpha: 0))
    }

    /// Sets a sublayer's frame, animating its size and place additively during a prop change.
    func animateFrame(_ layer: CALayer, _ frame: CGRect) {
        let (oldBounds, oldPosition) = (layer.bounds, layer.position)
        withoutActions { layer.frame = frame }
        guard changeMotion != nil, oldBounds.size != .zero else { return }
        if oldBounds.size != layer.bounds.size {
            let delta = CGRect(x: 0, y: 0, width: oldBounds.width - layer.bounds.width, height: oldBounds.height - layer.bounds.height)
            animateAdditive(layer, "bounds", from: NSValue(rect: delta), zero: NSValue(rect: .zero))
        }
        if oldPosition != layer.position {
            let delta = CGPoint(x: oldPosition.x - layer.position.x, y: oldPosition.y - layer.position.y)
            animateAdditive(layer, "position", from: NSValue(point: delta), zero: NSValue(point: .zero))
        }
    }

    /// The node's `opacity`, animated during a prop change.
    func setOpacity(_ alpha: CGFloat) {
        guard let layer, alphaValue != alpha else { return }
        let old = Double(layer.opacity)
        alphaValue = alpha
        animateAdditive(layer, "opacity", from: NSNumber(value: old - Double(alpha)), zero: NSNumber(value: 0))
    }

    // MARK: Configure and layout

    /// The props that do not wait for layout: `blur`, and the settings subscription a loop needs.
    func configureMotion() {
        configureBlur()
        if node.loop != nil {
            if motionSubscription == nil {
                motionSubscription = Motion.changes.subscribe { [weak self] _ in
                    self?.appliedLoop = nil
                    self?.needsLayout = true
                }
            }
        } else {
            motionSubscription = nil
        }
    }

    /// `blur`: a Gaussian content filter (Core Image filters on only while one is set).
    private func configureBlur() {
        guard let layer else { return }
        let radius = Float(node.blurRadius)
        let current = contentFilters.lazy.compactMap { $0 as? CIGaussianBlur }.first
        guard radius > 0 || current != nil else { return }
        if let current, current.radius == radius { return }
        let animation = changeMotion.flatMap { motion in
            Motion.canAnimate(in: self) ? Motion.appScenes.sceneAnimation(motion, "filters.blur.inputRadius",
                                                                           from: NSNumber(value: current?.radius ?? 0), to: NSNumber(value: radius), in: window) : nil
        }
        if radius == 0, animation == nil {
            contentFilters = []
            return
        }
        let filter = CIFilter.gaussianBlur()
        filter.name = "blur"
        filter.radius = radius
        layerUsesCoreImageFilters = true
        contentFilters = [filter]
        if let animation {
            // Animated down to nothing: the filter goes once the blur is gone, so no Core Image
            // pass keeps running at radius 0.
            CATransaction.begin()
            if radius == 0 {
                CATransaction.setMainCompletion { [weak self] in
                    guard let self, self.node.blurRadius == 0 else { return }
                    self.contentFilters = []
                }
            }
            layer.add(animation, forKey: "scene.blur")
            CATransaction.commit()
        }
    }

    /// `glow` on ``glowLayer``: color, radius and opacity animate during a prop change.
    func paintGlow() {
        guard let target = glowLayer else { return }
        if let glow = node.glow, let color = glow.color.sceneColor {
            target.shadowOffset = .zero
            animateColor(target, \.shadowColor, "shadowColor", color.cgColor)
            animateNumber(target, \.shadowRadius, "shadowRadius", glow.radius)
            animateNumber(target, \.shadowOpacity, "shadowOpacity", glow.opacity)
        } else if target.shadowOpacity != 0 {
            animateNumber(target, \.shadowOpacity, "shadowOpacity", 0)
        }
    }

    /// A glowing node with a fill casts its shadow from its rounded bounds (no offscreen pass).
    func layoutGlowPath() {
        guard let layer, glowLayer === layer else { return }
        let filled = node.props["background"] != nil || gradientLayer != nil
        layer.shadowPath = node.glow != nil && filled
            ? CGPath(roundedRect: bounds, cornerWidth: min(layer.cornerRadius, bounds.width / 2), cornerHeight: min(layer.cornerRadius, bounds.height / 2), transform: nil) : nil
    }

    /// `gradient` behind the content of a node that is not a shape.
    func paintGradientBackground() {
        guard drawsGradientBackground, let layer else { return }
        guard let gradient = node.gradient else {
            gradientLayer?.removeFromSuperlayer()
            gradientLayer = nil
            return
        }
        let fill = gradientLayer ?? {
            let fill = Self.makeGradientLayer()
            layer.insertSublayer(fill, at: 0)
            gradientLayer = fill
            return fill
        }()
        animateColors(fill, gradient.colors.compactMap { $0.sceneColor?.cgColor })
    }

    func layoutGradientBackground() {
        guard let fill = gradientLayer, let layer, let gradient = node.gradient else { return }
        animateFrame(fill, bounds)
        fill.cornerRadius = layer.cornerRadius
        let (start, end) = gradient.endpoints(yDown: fill.contentsAreFlipped())
        fill.startPoint = start
        fill.endPoint = end
    }

    /// A gradient layer with no implicit actions (a prop change animates it explicitly).
    static func makeGradientLayer() -> CAGradientLayer {
        let fill = CAGradientLayer()
        fill.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "startPoint": NSNull(),
                        "endPoint": NSNull(), "cornerRadius": NSNull(), "frame": NSNull()]
        fill.cornerCurve = .continuous
        fill.masksToBounds = true
        return fill
    }

    /// The loop and a pending enter transition (after the content's layout, at the final size).
    func layoutMotion() {
        layoutLoop()
        if enterPending, window != nil, !bounds.isEmpty {
            enterPending = false
            playTransition(entering: true)
        }
    }

    func motionWindowChanged() {
        if window == nil {
            stopLoop()
        } else if node.loop != nil || enterPending {
            needsLayout = true
        }
    }

    // MARK: Loop

    private func layoutLoop() {
        guard let layer else { return }
        guard let loop = node.loop, window != nil else { return stopLoop() }
        if let applied = appliedLoop, applied.loop == loop, applied.size == bounds.size { return }
        // The same loop at a new size keeps its phase.
        let begin = appliedLoop.flatMap { $0.loop == loop ? $0.begin : nil } ?? layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.removeAnimation(forKey: "scene.loop")
        shimmerClip?.removeFromSuperlayer()
        shimmerClip = nil
        appliedLoop = (loop, bounds.size, begin)
        if loop.effect == .shimmer { return addShimmer(loop, begin: begin) }
        guard let animation = Motion.appScenes.sceneLoopAnimation(loop, in: SceneTransformSpace(layer: layer)) else { return }
        animation.beginTime = begin
        layer.add(animation, forKey: "scene.loop")
    }

    func stopLoop() {
        layer?.removeAnimation(forKey: "scene.loop")
        shimmerClip?.removeFromSuperlayer()
        shimmerClip = nil
        appliedLoop = nil
    }

    /// `shimmer`: a soft light band crossing the node, clipped to its outline, over its content.
    private func addShimmer(_ loop: SceneLoop, begin: CFTimeInterval) {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        let width = max(bounds.width * 0.35, 24)
        guard let sweep = Motion.appScenes.sceneShimmerAnimation(loop, travel: bounds.width, band: width) else { return }
        let clip = CALayer()
        clip.actions = ["bounds": NSNull(), "position": NSNull()]
        clip.frame = layer.bounds
        clip.masksToBounds = true
        clip.cornerCurve = .continuous
        clip.cornerRadius = layer.cornerRadius
        clip.zPosition = 1000
        if let outline = shimmerOutline {
            let mask = CAShapeLayer()
            mask.frame = clip.bounds
            mask.path = outline
            clip.mask = mask
        }
        let band = CAGradientLayer()
        band.actions = ["bounds": NSNull(), "position": NSNull()]
        // A light sheen over any tone: white, faint, the band's peak in the middle.
        let peak = min(0.35 * loop.amount, 0.9)
        band.colors = [0, peak, 0].map { NSColor.white.withAlphaComponent(CGFloat($0)).cgColor }
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        band.position = CGPoint(x: -width / 2, y: bounds.height / 2)
        clip.addSublayer(band)
        layer.addSublayer(clip)
        sweep.beginTime = begin
        band.add(sweep, forKey: "scene.shimmer")
        shimmerClip = clip
    }

    // MARK: Transition

    /// Plays the node's `transition` in or out; false when it applies at once (no transition,
    /// Reduce Motion, not in a window that shows it). `completion` runs when every animation ends.
    @discardableResult
    func playTransition(entering: Bool, completion: (@MainActor () -> Void)? = nil) -> Bool {
        guard playsSDKTransition, let transition = node.transition, let layer, window != nil, Motion.canAnimate(in: self) else { return false }
        let animations = Motion.appScenes.sceneTransition(transition, entering: entering, opacity: layer.opacity,
                                                          in: SceneTransformSpace(layer: layer), window: window,
                                                          motion: node.transitionMotion)
        guard !animations.isEmpty else { return false }
        CATransaction.begin()
        if let completion {
            CATransaction.setMainCompletion(completion)
        }
        for (keyPath, animation) in animations {
            layer.add(animation, forKey: "scene.\(entering ? "enter" : "exit").\(keyPath)")
        }
        CATransaction.commit()
        return true
    }

    /// Whether this plays the node's `transition`: only in a widget tile (every other app scene draws
    /// as it did before widgets, AppSceneDefaultUnchangedTests), and only one the widget transitions
    /// (AppSceneNodeNSView+Transition: `opacity`, `slide`, `scale`, `move`) leave alone, `pop`.
    var playsSDKTransition: Bool { node.transition != nil && sceneTransition == nil && drawsInWidgetTile }

    /// Starts the exit of a node the scene removed from `host`: true when it plays (the view leaves
    /// `host` when it ends), false when the caller removes it now.
    func beginExit(from host: NSView) -> Bool {
        guard playsSDKTransition else { return false }
        exitToken &+= 1
        let token = exitToken
        exitHost = host
        // An enter still in flight keeps running: the exit adds to it, so nothing jumps.
        let started = playTransition(entering: false) { [weak self] in
            guard let self, self.exitToken == token, let host = self.exitHost, self.superview === host else { return }
            self.exitHost = nil
            self.removeFromSuperview()
            self.removeExitAnimations()
        }
        if !started { exitHost = nil }
        return started
    }

    /// The node is back in the scene (or moved to another parent) mid-exit: it shows again.
    func cancelExit() {
        exitHost = nil
        exitToken &+= 1
        removeExitAnimations()
    }

    private func removeExitAnimations() {
        for key in ["scene.exit.transform", "scene.exit.opacity"] { layer?.removeAnimation(forKey: key) }
    }
}
