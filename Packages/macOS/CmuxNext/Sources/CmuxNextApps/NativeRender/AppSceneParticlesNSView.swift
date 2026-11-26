import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups

/// `Particles`: a particle field the render server runs (`CAEmitterLayer`), with no script and no
/// layout per frame. `preset` is `confetti`, `sparkles`, `rain`, `snow`, `embers` or `stars` (any
/// other value draws nothing); `colors` tints it (theme tones or `#RRGGBB[AA]`; each preset has its
/// own tones by default); `rate` multiplies how many it emits (1 by default). `rain`, `snow`,
/// `embers` and `stars` emit all the time; `confetti` and `sparkles` emit only when `rate` is set.
/// `burst` is a counter: each time it grows, one burst fires from the middle.
///
/// It fills its frame (in a `ZStack`, the stack's whole size, behind the siblings after it) and
/// takes no input. It emits only while it is in a window, and not at all under Reduce Motion or
/// with the indicators' motion off.
///
/// `choreography` (a `cmux.particles/1` document, ABI "Particles choreography") draws a glyph of dots
/// centred in the frame instead (``AppSceneChoreographyGlyph``), and wins over `preset`; `trigger` and
/// `phase` say what it plays (read when a phase ends), `size` and `colors[0]` override the document's
/// particle size and color.
final class AppSceneParticlesNSView: AppSceneNodeNSView {
    enum Preset: String, CaseIterable {
        case confetti, sparkles, rain, snow, embers, stars

        /// Emits without a `rate`.
        var isContinuousByDefault: Bool { self != .confetti && self != .sparkles }
    }

    /// The steady field, at `rate`.
    let field = CAEmitterLayer()
    /// The burst set-up (cells, position, shape): it never emits; each burst plays on a copy in
    /// ``burstHost``, so a new burst never restarts the particles of the one before.
    let bursts = CAEmitterLayer()
    /// Holds the bursts in flight; each one leaves when its last particle is gone.
    let burstHost = CALayer()
    private var lastBurst: Double?
    /// What the cells were built for, so a redraw with nothing new keeps the particles in flight.
    private var built: (preset: Preset, colors: [CGColor], size: CGSize)?
    private var settings: MotionSubscription?
    /// The `choreography` glyph, while the prop parses.
    private(set) var glyph: AppSceneChoreographyGlyph?
    /// The window whose sight reports restart the glyph (its clock settles out of sight).
    private weak var followedWindow: NSWindow?

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        for emitter in [field, bursts] {
            emitter.actions = ["bounds": NSNull(), "position": NSNull(), "emitterPosition": NSNull(), "emitterSize": NSNull(), "birthRate": NSNull()]
            emitter.renderMode = .unordered
            layer?.addSublayer(emitter)
        }
        bursts.birthRate = 0
        burstHost.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer?.addSublayer(burstHost)
        settings = Motion.changes.subscribe { [weak self] _ in
            self?.updateEmission()
            self?.updateGlyph()
        }
        setAccessibilityElement(false)
    }

    var preset: Preset? { node.string("preset").flatMap(Preset.init(rawValue:)) }
    /// The preset it draws: none while a `choreography` glyph plays.
    var drawnPreset: Preset? { glyph == nil ? preset : nil }
    private var rate: Float {
        let given = AppSceneNode.finite(node.number("rate"), in: 0...10).map { Float($0) }
        guard let preset = drawnPreset else { return 0 }
        return given ?? (preset.isContinuousByDefault ? 1 : 0)
    }

    /// Whether it emits now: in a window, with loops on. A window that is covered or minimized is
    /// not drawn, so its emitter costs nothing there.
    var isEmitting: Bool {
        guard window != nil, Motion.appScenes.animatesLoops else { return false }
        return drawnPreset != nil
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        configureGlyph(node)
        let burst = node.number("burst").flatMap { $0.isFinite ? $0 : nil }
        if let burst, let lastBurst, burst > lastBurst { fireBurst() }
        lastBurst = burst
        updateEmission()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeOcclusion()
        updateEmission()
        updateGlyph()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Particles stay inside the node's frame (a long fall or a wide burst would cover its siblings).
    override var clipsContent: Bool { true }
    override func contentHeight(width: CGFloat) -> CGFloat { 0 }

    override func layoutContent(in rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for emitter in [field, bursts, burstHost] { emitter.frame = rect }
        for burst in burstHost.sublayers ?? [] { burst.frame = burstHost.bounds }
        CATransaction.commit()
        if let glyph {
            glyph.layout(center: CGPoint(x: rect.midX, y: rect.midY), size: glyphSize(glyph.choreography))
        }
        performWithTheme {
            buildCells()
            paintGlyph()
        }
    }

    override func paint() {
        buildCells()
        paintGlyph()
    }

    /// Fires one burst from the middle (nothing while it does not emit).
    func fireBurst() {
        guard isEmitting, let cells = bursts.emitterCells, !cells.isEmpty,
              let burst = Motion.appScenes.sceneBurstAnimation(lifetime: Self.longestLife(cells)) else { return }
        let emitter = CAEmitterLayer()
        emitter.actions = bursts.actions
        emitter.renderMode = bursts.renderMode
        emitter.emitterShape = bursts.emitterShape
        emitter.emitterMode = bursts.emitterMode
        emitter.emitterPosition = bursts.emitterPosition
        emitter.emitterSize = bursts.emitterSize
        emitter.emitterCells = cells
        emitter.birthRate = 0
        // A burst starts now, not from the emitter's own clock (which would pre-age the particles).
        emitter.beginTime = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = burstHost.bounds
        burstHost.addSublayer(emitter)
        CATransaction.setMainCompletion { [weak emitter] in emitter?.removeFromSuperlayer() }
        emitter.add(burst, forKey: "scene.burst")
        CATransaction.commit()
    }

    /// How long the longest-lived particle of `cells` (and their sub-cells) can last.
    static func longestLife(_ cells: [CAEmitterCell]) -> TimeInterval {
        cells.map { cell in
            TimeInterval(cell.lifetime + cell.lifetimeRange) + longestLife(cell.emitterCells ?? [])
        }.max() ?? 0
    }

    /// Starts or stops the steady field for the window, the settings and `rate`.
    func updateEmission() {
        let on = isEmitting
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.birthRate = on ? rate : 0
        // Off by the settings: nothing in flight stays on screen either.
        let still = !Motion.appScenes.animatesLoops
        field.isHidden = still
        burstHost.isHidden = still
        CATransaction.commit()
    }

    /// The cells for the preset, colors and size (only when one of them changed).
    private func buildCells() {
        guard let preset = drawnPreset else {
            field.emitterCells = nil
            bursts.emitterCells = nil
            built = nil
            return
        }
        let colors = (node.props["colors"]?.arrayValue ?? []).prefix(8).compactMap { $0.sceneColor?.cgColor }
        let tones = colors.isEmpty ? Self.defaultColors(preset) : colors
        let size = field.bounds.size
        if let built, built.preset == preset, built.colors == tones, built.size == size { return }
        built = (preset, tones, size)
        let down: CGFloat = field.contentsAreFlipped() ? 1 : -1
        ParticlePresets.configure(field, preset: preset, colors: tones, size: size, down: down, burst: false)
        ParticlePresets.configure(bursts, preset: preset, colors: tones, size: size, down: down, burst: true)
        updateEmission()
    }

    // MARK: Choreography

    /// Builds the glyph for a new `choreography` value (none when it does not parse), or hands the
    /// running one the node's `trigger` and `phase`.
    private func configureGlyph(_ node: AppSceneNode) {
        let request = AppSceneChoreography.Request(phase: Self.text(node.props["phase"]), trigger: Self.text(node.props["trigger"]))
        let document = node.props["choreography"]
        if let glyph, let document, glyph.document == document {
            glyph.setRequest(request)
            return
        }
        if let glyph {
            glyph.stop()
            glyph.host.removeFromSuperlayer()
            self.glyph = nil
        }
        guard let document, let choreography = AppSceneChoreography(json: document) else { return }
        let made = AppSceneChoreographyGlyph(document: document, choreography: choreography, request: request)
        layer?.addSublayer(made.host)
        glyph = made
        needsLayout = true
        updateGlyph()
    }

    /// A non-empty string prop, else nil.
    private static func text(_ value: AppJSON?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }

    /// `size` (points, above 0) over the document's `particle.size`.
    private func glyphSize(_ choreography: AppSceneChoreography) -> CGFloat {
        if let size = AppSceneNode.finite(node.number("size"), in: 0...256), size > 0 { return CGFloat(size) }
        return CGFloat(choreography.size)
    }

    /// `colors[0]`, else the document's `particle.color`, else the accent (in the theme scope).
    private func paintGlyph() {
        guard let glyph else { return }
        let color = node.props["colors"]?.arrayValue?.first?.sceneColor
            ?? AppJSON.string(glyph.choreography.color).sceneColor
            ?? Palette.accentFill
        glyph.paint(color: color.cgColor)
    }

    /// Starts or stops the glyph's clock for the window and the motion settings.
    func updateGlyph() {
        glyph?.update(in: self)
    }

    /// Follows the window's sight reports (from the app's one occlusion observer): back in sight,
    /// the glyph's clock starts again.
    private func observeOcclusion() {
        guard followedWindow !== window else { return }
        if let followedWindow { FrameScheduler.unfollowSight(of: followedWindow, owner: self) }
        followedWindow = window
        guard let window else { return }
        FrameScheduler.followSight(of: window, owner: self) { [weak self] in self?.updateGlyph() }
    }

    /// Each preset's tones from the theme, so it reads right in light and dark.
    static func defaultColors(_ preset: Preset) -> [CGColor] {
        let tones: [NSColor] = switch preset {
        case .confetti: [Palette.success, Palette.attention, Palette.danger, Palette.textPrimary]
        case .sparkles: [Palette.attention, Palette.textPrimary]
        case .rain: [Palette.textSecondary]
        case .snow: [Palette.textPrimary]
        case .embers: [Palette.attention, Palette.danger]
        case .stars: [Palette.textPrimary, Palette.textSecondary]
        }
        return tones.map(\.cgColor)
    }
}

/// The emitter set-up of each preset: where it emits, how much per area, and its particles.
enum ParticlePresets {
    /// Sets `emitter` up for `preset` over `size` points; `down` is +1 when +y is down on screen.
    /// A burst emitter fires from the middle; a steady one covers its edge or area.
    static func configure(_ emitter: CAEmitterLayer, preset: AppSceneParticlesNSView.Preset, colors: [CGColor],
                          size: CGSize, down: CGFloat, burst: Bool) {
        let (w, h) = (max(size.width, 1), max(size.height, 1))
        let top = down > 0 ? 0 : h
        let bottom = h - top
        let fall: CGFloat = down > 0 ? .pi / 2 : -.pi / 2
        let share = Float(1) / Float(max(colors.count, 1))
        // Steady fields scale with their edge or area, capped so a huge pane stays cheap.
        let perEdge = Float(min(w, 2000) / 100)
        let perArea = Float(min(w * h, 1_000_000) / 10_000)
        let image: CGImage? = switch preset {
        case .confetti: ParticleImages.confetti
        case .sparkles, .stars: ParticleImages.sparkle
        case .rain: ParticleImages.streak
        case .snow, .embers: ParticleImages.dot
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if burst {
            emitter.emitterShape = .point
            emitter.emitterPosition = CGPoint(x: w / 2, y: h / 2)
            emitter.emitterSize = .zero
            emitter.emitterCells = colors.map { color in
                let cell = CAEmitterCell()
                cell.contents = image
                cell.color = color
                cell.birthRate = 360 * share
                if preset == .confetti {
                    // Up and out in a fan, then falling and turning.
                    cell.lifetime = 2.6
                    cell.velocity = 240
                    cell.velocityRange = 90
                    cell.emissionLongitude = -fall
                    cell.emissionRange = .pi / 2.4
                    cell.yAcceleration = 320 * down
                    cell.spin = 3
                    cell.spinRange = 8
                    cell.scale = 0.7
                    cell.scaleRange = 0.3
                    cell.alphaSpeed = -0.35
                } else {
                    // Every way at once, shrinking and fading out.
                    cell.lifetime = 1
                    cell.velocity = 130
                    cell.velocityRange = 70
                    cell.emissionRange = 2 * .pi
                    cell.scale = 0.5
                    cell.scaleRange = 0.3
                    cell.scaleSpeed = -0.4
                    cell.alphaSpeed = -1
                    cell.spin = 1
                    cell.spinRange = 3
                }
                return cell
            }
            return
        }
        switch preset {
        case .confetti, .rain, .snow:
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: w / 2, y: top)
            emitter.emitterSize = CGSize(width: w, height: 1)
        case .embers:
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: w / 2, y: bottom)
            emitter.emitterSize = CGSize(width: w, height: 1)
        case .sparkles, .stars:
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .surface
            emitter.emitterPosition = CGPoint(x: w / 2, y: h / 2)
            emitter.emitterSize = CGSize(width: w, height: h)
        }
        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = image
            cell.color = color
            switch preset {
            case .confetti:
                cell.birthRate = 6 * perEdge * share
                cell.lifetime = Float(h / 50 + 1)
                cell.velocity = 60
                cell.velocityRange = 30
                cell.emissionLongitude = fall
                cell.emissionRange = .pi / 6
                cell.yAcceleration = 40 * down
                cell.spin = 2
                cell.spinRange = 6
                cell.scale = 0.6
                cell.scaleRange = 0.25
            case .sparkles:
                cell.birthRate = 4 * perArea * share
                cell.lifetime = 1.2
                cell.velocity = 6
                cell.emissionRange = 2 * .pi
                cell.scale = 0.45
                cell.scaleRange = 0.25
                cell.scaleSpeed = -0.3
                cell.alphaSpeed = -0.8
            case .rain:
                cell.birthRate = 24 * perEdge * share
                cell.lifetime = Float((h + 40) / 380)
                cell.velocity = 420
                cell.velocityRange = 60
                cell.emissionLongitude = fall
                cell.alphaRange = 0.3
                cell.scale = 0.7
                cell.scaleRange = 0.2
            case .snow:
                cell.birthRate = 3 * perEdge * share
                cell.lifetime = Float(min(h / 22 + 2, 20))
                cell.velocity = 26
                cell.velocityRange = 12
                cell.emissionLongitude = fall
                cell.emissionRange = .pi / 8
                cell.scale = 0.3
                cell.scaleRange = 0.2
                cell.alphaRange = 0.4
            case .embers:
                cell.birthRate = 4 * perEdge * share
                cell.lifetime = Float(min(h / 30 + 1, 8))
                cell.velocity = 34
                cell.velocityRange = 18
                cell.emissionLongitude = -fall
                cell.emissionRange = .pi / 7
                cell.scale = 0.28
                cell.scaleRange = 0.18
                cell.scaleSpeed = -0.04
                cell.alphaSpeed = -0.25
            case .stars:
                cell.birthRate = 1.5 * perArea * share
                cell.lifetime = 3
                cell.lifetimeRange = 1.5
                cell.scale = 0.22
                cell.scaleRange = 0.14
                cell.alphaRange = 0.5
                cell.alphaSpeed = -0.3
            }
            return cell
        }
    }
}

/// White particle images, drawn once; each cell tints its own with its color.
@MainActor
enum ParticleImages {
    static let dot = draw(side: 16) { context, rect in
        let colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0.2, 1]) {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: rect.width / 2, options: [])
        }
    }
    static let confetti = draw(width: 10, height: 6) { context, rect in
        context.fill(rect)
    }
    static let streak = draw(width: 2, height: 16) { context, rect in
        context.fill(rect)
    }
    /// A four-point sparkle.
    static let sparkle = draw(side: 20) { context, rect in
        let (c, r, waist) = (CGPoint(x: rect.midX, y: rect.midY), rect.width / 2, rect.width * 0.09)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + waist, y: c.y - waist))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + waist, y: c.y + waist))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - waist, y: c.y + waist))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - waist, y: c.y - waist))
        context.addPath(path)
        context.fillPath()
    }

    private static func draw(side: Int, _ body: (CGContext, CGRect) -> Void) -> CGImage? { draw(width: side, height: side, body) }

    private static func draw(width: Int, height: Int, _ body: (CGContext, CGRect) -> Void) -> CGImage? {
        let scale = 2
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context else { return nil }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.setFillColor(NSColor.white.cgColor)
        body(context, CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
