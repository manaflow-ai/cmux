public import AppKit
public import QuartzCore

/// The one status indicator every surface draws (sidebar rows and group
/// headers, sidebar section items, tabs, Home, pane headers). It owns one
/// plain CALayer (`layer`) so the layer-only tab strip can host it as
/// cheaply as views can (`StatusIndicatorView` wraps it); the host adds
/// `layer` and sets `frame`. Sublayers exist only while a glyph
/// needs them; every animation runs in the render server and is removed as
/// soon as the plan has none, so an idle or hidden indicator costs no frames
/// and no wakeups.
@MainActor
public final class StatusIndicatorLayer {
    /// The host adds this to its layer tree.
    public let layer = CALayer()
    /// Resolved colors, set by the host inside its theme scope.
    public struct Colors: Equatable {
        public var loading: CGColor
        public var attention: CGColor
        public var danger: CGColor
        public var success: CGColor
        /// Agent work (`Tint.accent`); the loading color when nil.
        public var accent: CGColor?

        public init(loading: CGColor, attention: CGColor, danger: CGColor, success: CGColor, accent: CGColor? = nil) {
            self.loading = loading
            self.attention = attention
            self.danger = danger
            self.success = success
            self.accent = accent
        }

        /// The theme's colors (call inside `performWithTheme` / a theme
        /// scope). `color` overrides the loading color
        /// (`appearance.statusIndicator.color`).
        public static func current(loading color: ThemeRGB?) -> Colors {
            Colors(loading: color?.nsColor.cgColor ?? Palette.textSecondary.cgColor,
                   attention: Palette.attention.cgColor,
                   danger: Palette.danger.cgColor,
                   success: Palette.success.cgColor,
                   accent: Palette.textPrimary.cgColor)
        }

        /// The color a plan's tint draws in.
        public func color(for tint: StatusIndicatorPlan.Tint) -> CGColor {
            switch tint {
            case .loading: loading
            case .attention: attention
            case .danger: danger
            case .success: success
            case .accent: accent ?? loading
            }
        }
    }

    public private(set) var plan: StatusIndicatorPlan = .hidden
    public private(set) var config = StatusIndicatorConfig()
    public var colors: Colors? {
        didSet { if colors != oldValue { applyColors() } }
    }

    private var glyphLayer: CAShapeLayer?
    private var trackLayer: CAShapeLayer?
    private var nativeLayer: CALayer?
    /// The pixel side the native mask was rendered for.
    private var nativeSide: CGFloat = 0
    /// Braille spinner frames (masks) for the current size and font.
    private var brailleLayer: CALayer?
    private var brailleFrames: [CGImage] = []
    /// The working dots: a replicator of one dot (`StatusIndicatorLayer+Dots`).
    var dotsLayer: CAReplicatorLayer?
    /// A status icon set's mark: a tinted layer masked by `StatusMarkArt`
    /// (`StatusIndicatorLayer+Mark`), and what its mask was drawn for.
    var markLayer: CALayer?
    var markKey: StatusMarkKey?

    public init() {
        layer.actions = Self.noActions
        layer.isHidden = true
    }

    /// Frame in the host's layer coordinates; relays out the glyph.
    public var frame: CGRect {
        get { layer.frame }
        set {
            guard newValue != layer.frame else { return }
            layer.frame = newValue
            relayout()
        }
    }

    /// Backing scale of the host's window.
    public var contentsScale: CGFloat = 2 {
        didSet { if contentsScale != oldValue { relayout() } }
    }

    /// Whether the host's coordinate space is flipped (top-left origin).
    /// Nil asks Core Animation (`contentsAreFlipped` of the superlayer),
    /// which is right for plain layer trees like the tab strip; a view host
    /// passes its own `isFlipped`, because AppKit's backing layers report
    /// the flip of their ancestors.
    public var hostIsFlipped: Bool? {
        didSet { if hostIsFlipped != oldValue { relayout() } }
    }

    /// Bounds of `layer`.
    var bounds: CGRect { layer.bounds }
    static let noActions: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
        "path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "backgroundColor": NSNull(),
        "strokeEnd": NSNull(), "lineWidth": NSNull(), "sublayers": NSNull(), "transform": NSNull(), "mask": NSNull(),
    ]

    /// The animation running now (tests, diagnostics).
    public var runningAnimation: StatusIndicatorPlan.Animation? {
        for (sublayer, key) in [(glyphLayer as CALayer?, "spin"), (nativeLayer, "step"), (glyphLayer, "pulse"), (markLayer, "pulse"), (brailleLayer?.mask, "frames"), (dotsLayer?.sublayers?.first, "wave")] {
            if let sublayer, sublayer.animation(forKey: key) != nil {
                return StatusIndicatorPlan.Animation(key: key)
            }
        }
        return nil
    }

    /// Number of sublayers alive (tests: idle must be zero).
    public var liveSublayerCount: Int { layer.sublayers?.count ?? 0 }

    /// Show `plan` with `config`. Cheap when nothing changed.
    public func apply(_ plan: StatusIndicatorPlan, config: StatusIndicatorConfig) {
        guard plan != self.plan || config != self.config else { return }
        let configChanged = config != self.config
        let glyphChanged = plan.glyph != self.plan.glyph || configChanged
        self.plan = plan
        self.config = config
        layer.isHidden = plan.glyph == .none
        if glyphChanged { rebuild() }
        applyColors()
        // New loop timing or pulse depth: restart the running animation.
        if configChanged { removeAllAnimations() }
        updateAnimation()
    }

    /// Rebuilds the glyph for the current frame and scale. Hosts call it
    /// after they add `layer` to a (possibly flipped) tree.
    public func relayout() {
        // Sublayers draw in unflipped (bottom-left) space whatever the host
        // uses, so the arc, the check and the rotation direction are the
        // same in the flipped tab strip and in plain views.
        let flipped = hostIsFlipped ?? layer.superlayer?.contentsAreFlipped() ?? false
        if layer.isGeometryFlipped != flipped { layer.isGeometryFlipped = flipped }
        rebuild()
        updateAnimation()
    }

    // MARK: Geometry

    /// The square the glyph fills: the host's bounds scaled by the setting.
    var glyphRect: CGRect {
        let side = min(bounds.width, bounds.height) * config.settings.scale
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    private func rebuild() {
        let rect = glyphRect
        let thickness = config.settings.thickness
        if case .mark = plan.glyph {} else { removeMark() }
        switch plan.glyph {
        case .none:
            removeGlyph(); removeTrack(); removeNative(); removeBraille(); removeDots()
        case .arc:
            removeTrack(); removeNative(); removeBraille(); removeDots()
            let shape = makeGlyph(frame: rect)
            shape.path = CGPath(ellipseIn: shape.bounds.insetBy(dx: thickness / 2, dy: thickness / 2), transform: nil)
            shape.fillColor = nil
            shape.lineWidth = thickness
            shape.strokeStart = 0
            shape.strokeEnd = config.arcLength
        case .ring(let progress):
            removeNative(); removeBraille(); removeDots()
            let track = makeTrack(frame: rect)
            track.path = StatusGlyphGeometry.ringPath(in: track.bounds, thickness: thickness)
            track.lineWidth = thickness
            track.opacity = Float(config.trackOpacity)
            let shape = makeGlyph(frame: rect)
            shape.path = StatusGlyphGeometry.ringPath(in: shape.bounds, thickness: thickness)
            shape.fillColor = nil
            shape.lineWidth = thickness
            shape.strokeStart = 0
            shape.strokeEnd = progress
        case .native:
            removeGlyph(); removeTrack(); removeBraille(); removeDots()
            let native = makeNative(frame: rect)
            let scale = contentsScale
            if nativeSide != rect.width * scale {
                nativeSide = rect.width * scale
                native.mask?.contents = NativeSpinnerImage.image(side: rect.width, scale: scale)
            }
        case .dot:
            removeTrack(); removeNative(); removeBraille(); removeDots()
            let shape = makeGlyph(frame: rect)
            let side = rect.width * config.dotScale
            shape.path = CGPath(ellipseIn: CGRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2, width: side, height: side), transform: nil)
            shape.lineWidth = 0
            shape.strokeEnd = 1
        case .check:
            removeTrack(); removeNative(); removeBraille(); removeDots()
            let shape = makeGlyph(frame: rect)
            shape.path = StatusGlyphGeometry.checkPath(in: StatusGlyphGeometry.checkRect(in: shape.bounds))
            shape.fillColor = nil
            shape.lineWidth = max(thickness, 1.25)
            shape.lineJoin = .round
            shape.strokeStart = 0
            shape.strokeEnd = 1
        case .braille:
            removeGlyph(); removeTrack(); removeNative(); removeDots()
            let braille = makeBraille(frame: rect)
            let frames = BrailleSpinnerImage.images(side: rect.width, scale: contentsScale, family: config.terminalFontFamily)
            if frames != brailleFrames {
                brailleFrames = frames
                braille.mask?.removeAllAnimations()
                braille.mask?.contents = frames.first
            }
        case .dots:
            removeGlyph(); removeTrack(); removeNative(); removeBraille()
            buildDots(in: rect)
        case .bars:
            removeGlyph(); removeTrack(); removeNative(); removeBraille()
            buildDots(in: rect, bars: true)
        case .mark(let mark):
            removeGlyph(); removeTrack(); removeNative(); removeBraille(); removeDots()
            buildMark(mark, in: rect)
        }
    }

    // MARK: Sublayers

    private func makeGlyph(frame: CGRect) -> CAShapeLayer {
        let shape = glyphLayer ?? {
            let shape = CAShapeLayer()
            shape.actions = Self.noActions
            shape.lineCap = .round
            layer.addSublayer(shape)
            glyphLayer = shape
            return shape
        }()
        shape.contentsScale = contentsScale
        if shape.frame != frame { shape.frame = frame }
        return shape
    }

    private func makeTrack(frame: CGRect) -> CAShapeLayer {
        let track = trackLayer ?? {
            let track = CAShapeLayer()
            track.actions = Self.noActions
            track.fillColor = nil
            layer.insertSublayer(track, at: 0)
            trackLayer = track
            return track
        }()
        track.contentsScale = contentsScale
        if track.frame != frame { track.frame = frame }
        return track
    }

    private func makeNative(frame: CGRect) -> CALayer {
        let native = nativeLayer ?? {
            let native = CALayer()
            native.actions = Self.noActions
            let mask = CALayer()
            mask.actions = Self.noActions
            mask.contentsGravity = .resizeAspect
            native.mask = mask
            layer.addSublayer(native)
            nativeLayer = native
            return native
        }()
        if native.frame != frame {
            native.frame = frame
            native.mask?.frame = native.bounds
        }
        native.mask?.contentsScale = contentsScale
        return native
    }

    private func makeBraille(frame: CGRect) -> CALayer {
        let braille = brailleLayer ?? {
            let braille = CALayer()
            braille.actions = Self.noActions
            let mask = CALayer()
            mask.actions = Self.noActions
            mask.contentsGravity = .resizeAspect
            braille.mask = mask
            layer.addSublayer(braille)
            brailleLayer = braille
            return braille
        }()
        if braille.frame != frame {
            braille.frame = frame
            braille.mask?.frame = braille.bounds
        }
        braille.mask?.contentsScale = contentsScale
        return braille
    }

    private func removeGlyph() {
        glyphLayer?.removeFromSuperlayer()
        glyphLayer = nil
    }

    private func removeTrack() {
        trackLayer?.removeFromSuperlayer()
        trackLayer = nil
    }

    private func removeNative() {
        nativeLayer?.removeFromSuperlayer()
        nativeLayer = nil
        nativeSide = 0
    }

    private func removeBraille() {
        brailleLayer?.removeFromSuperlayer()
        brailleLayer = nil
        brailleFrames = []
    }

    private func removeAllAnimations() {
        glyphLayer?.removeAllAnimations()
        markLayer?.removeAllAnimations()
        nativeLayer?.removeAllAnimations()
        brailleLayer?.mask?.removeAllAnimations()
        dotsLayer?.sublayers?.first?.removeAllAnimations()
    }

    // MARK: Color and motion

    private func applyColors() {
        guard let colors else { return }
        let color = colors.color(for: plan.tint)
        markLayer?.backgroundColor = color
        switch plan.glyph {
        case .dot:
            glyphLayer?.fillColor = color
            glyphLayer?.strokeColor = nil
        default:
            glyphLayer?.strokeColor = color
            glyphLayer?.fillColor = nil
        }
        trackLayer?.strokeColor = color
        nativeLayer?.backgroundColor = color
        brailleLayer?.backgroundColor = color
        (dotsLayer?.sublayers?.first as? CAShapeLayer)?.fillColor = color
    }

    private func updateAnimation() {
        let wanted = plan.animation
        guard wanted != runningAnimation else { return }
        removeAllAnimations()
        guard let wanted, let target = animationTarget(for: wanted) else { return }
        let animation: CAAnimation? = switch wanted {
        case .spin: Motion.spinAnimation()
        case .step: Motion.stepAnimation(steps: config.nativeSteps)
        case .pulse: Motion.pulseAnimation(low: Float(config.pulseLow))
        case .frames: Motion.framesAnimation(brailleFrames)
        case .wave: waveAnimation()
        }
        if let animation { target.add(animation, forKey: wanted.key) }
    }

    private func animationTarget(for animation: StatusIndicatorPlan.Animation?) -> CALayer? {
        switch animation {
        case .step?: nativeLayer
        case .frames?: brailleLayer?.mask
        case .spin?, .pulse?: markLayer ?? glyphLayer
        case .wave?: dotsLayer?.sublayers?.first
        case nil: nil
        }
    }
}
