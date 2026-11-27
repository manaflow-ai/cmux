public import AppKit
import QuartzCore

/// Sleepy Mode's night sky: 90 twinkling stars and three Zs rising from the moon's corner, as
/// Core Animation layers whose loops run in the render server.
///
/// The sky was a SwiftUI `Canvas` in a `TimelineView` at 10 frames a second: every frame the
/// main thread drew 90 stars and three text runs over the whole screen, 20-38 ms each in the
/// every-action sweep (m27 other-main-work, `SleepySceneView.drawSky`), a third of the main
/// thread while the scene showed and agents worked. Here the main thread builds the layers once
/// (and again only when the size changes); no frame runs app code.
///
/// The stars sit at fixed spots (a seeded walk, the same on every launch); the look matches the
/// canvas: a star's opacity follows `0.35 + 0.65 * (0.5 + 0.5 * sin(1.3 t + phase))`, and each Z
/// rises 90 points over 3 s, drifting right and wobbling, from 18 to 36 points while it fades.
///
/// ```swift
/// let sky = NightSkyView()
/// sky.loops = Motion.panes.animatesLoops
/// ```
public final class NightSkyView: NSView {
    /// Whether the stars twinkle and the Zs rise; false shows the still sky (the canvas at time 0).
    public var loops = true {
        didSet { if loops != oldValue { rebuild() } }
    }

    private let root = CALayer()
    private var stars: [CALayer] = []
    private var zs: [CATextLayer] = []
    private var builtSize: CGSize = .zero

    public override init(frame: NSRect) {
        super.init(frame: frame)
        root.actions = Self.noActions
        layer = root
        wantsLayer = true
        for _ in 0..<Self.starCount {
            let star = CALayer()
            star.actions = Self.noActions
            star.backgroundColor = NSColor.white.cgColor
            root.addSublayer(star)
            stars.append(star)
        }
        for _ in 0..<Self.zCount {
            let z = CATextLayer()
            z.actions = Self.noActions
            z.string = Self.zText
            z.alignmentMode = .center
            z.foregroundColor = NSColor.white.cgColor
            z.font = Self.zFont
            z.fontSize = Self.zFontSize
            z.bounds = CGRect(x: 0, y: 0, width: Self.zFontSize, height: Self.zFontSize * 1.3)
            root.addSublayer(z)
            zs.append(z)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    // cx-t7hu: not an isolated deinit (its runtime hop traps when released inside an action's scope).
    nonisolated deinit {}

    /// Clicks go to the scene around the sky (a click anywhere wakes Sleepy Mode).
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for z in zs { z.contentsScale = scale }
    }

    /// Places every layer for the current size and (re)starts or stops the loops.
    private func rebuild() {
        let size = bounds.size
        builtSize = size
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for star in stars {
            // The canvas's top-left point, in this view's bottom-left coordinates.
            let x = next() * size.width, y = size.height - next() * size.height
            let phase = next() * .pi * 2, radius = 0.6 + next() * 1.4
            star.frame = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            star.cornerRadius = radius
            star.opacity = Float(Self.starAlpha(time: 0, phase: phase))
            star.removeAllAnimations()
            if loops { star.add(Self.twinkle(phase: phase), forKey: "twinkle") }
        }
        let origin = CGPoint(x: size.width / 2 + 60, y: size.height / 2 + 150)
        for (index, z) in zs.enumerated() {
            let start = Double(index) / Double(Self.zCount)
            z.position = Self.zPoint(origin: origin, progress: start)
            z.opacity = Float(1 - start)
            z.setAffineTransform(Self.zScale(progress: start))
            z.removeAllAnimations()
            if loops { z.add(Self.rise(origin: origin, offset: start * Self.risePeriod), forKey: "rise") }
        }
    }

    // MARK: The scene's look

    private static let starCount = 90
    private static let zCount = 3
    private static let zText = "z"
    /// The Zs render at their largest size and scale down, so the text stays sharp.
    private static let zFontSize: CGFloat = 36
    private static let zFont: NSFont = {
        let base = NSFont.systemFont(ofSize: zFontSize, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: zFontSize) } ?? base
    }()
    /// One twinkle: `sin(1.3 t)` repeats every 2π / 1.3 seconds.
    private static let twinklePeriod: CFTimeInterval = 2 * .pi / 1.3
    /// One Z's rise.
    private static let risePeriod: CFTimeInterval = 3
    private static let riseSteps = 30
    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "opacity": NSNull(),
        "transform": NSNull(), "cornerRadius": NSNull(), "contents": NSNull(), "sublayers": NSNull(),
    ]

    static func starAlpha(time: Double, phase: Double) -> Double {
        0.35 + 0.65 * (0.5 + 0.5 * sin(time * 1.3 + phase))
    }

    static func zPoint(origin: CGPoint, progress: Double) -> CGPoint {
        CGPoint(x: origin.x + progress * 50 + sin(progress * .pi * 2) * 8, y: origin.y + progress * 90)
    }

    /// A Z's size at `progress`: 18 points rising to 36, drawn at 36.
    static func zScale(progress: Double) -> CGAffineTransform {
        let scale = (18 + progress * 18) / zFontSize
        return CGAffineTransform(scaleX: scale, y: scale)
    }

    /// A star's opacity between 0.35 and 1, eased like a sine, at the phase it has at time 0.
    private static func twinkle(phase: Double) -> CAAnimation {
        // motion: allow Sleepy Mode's own star loop; added only while Motion.panes.animatesLoops (SleepySceneView)
        let twinkle = CABasicAnimation(keyPath: "opacity")
        twinkle.fromValue = 0.35
        twinkle.toValue = 1.0
        let half = twinklePeriod / 2
        twinkle.duration = half
        twinkle.autoreverses = true
        twinkle.repeatCount = .infinity
        // motion: allow the ease that follows the canvas's sine; same gate as the loop above
        twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        twinkle.isRemovedOnCompletion = false
        // Local time 0 is the darkest point, sin(1.3 t + phase) = -1; at time 0 the star is
        // (π/2 + phase) / 1.3 seconds past it.
        twinkle.timeOffset = ((.pi / 2 + phase) / 1.3).truncatingRemainder(dividingBy: twinklePeriod)
        return twinkle
    }

    /// A Z's rise, drift, growth and fade, `offset` seconds into its 3 s loop.
    private static func rise(origin: CGPoint, offset: CFTimeInterval) -> CAAnimation {
        let steps = (0...riseSteps).map { Double($0) / Double(riseSteps) }
        // motion: allow Sleepy Mode's own Z loop; added only while Motion.panes.animatesLoops (SleepySceneView)
        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = steps.map { NSValue(point: zPoint(origin: origin, progress: $0)) }
        // motion: allow part of the Z loop above, same gate
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1.0, 0.0]
        // motion: allow part of the Z loop above, same gate
        let grow = CAKeyframeAnimation(keyPath: "transform")
        grow.values = [0.0, 1.0].map { NSValue(caTransform3D: CATransform3DMakeAffineTransform(zScale(progress: $0))) }
        // motion: allow the Z loop's group; same gate
        let group = CAAnimationGroup()
        for part in [path, fade, grow] { part.duration = risePeriod }
        group.animations = [path, fade, grow]
        group.duration = risePeriod
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.timeOffset = offset
        return group
    }
}
