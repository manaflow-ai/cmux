import CmuxConversationCore
import CoreGraphics
import Foundation
import QuartzCore

// The conversation background behind the transcript, shared by the iOS and
// macOS surfaces. Core Animation only, top-left-origin coordinates (UIKit, or
// a flipped AppKit view). Dynamic backgrounds are approximations of Messages'
// Sky, Water, Aurora and Glitter posters (those are RealityKit VFX scenes in
// DynamicBackgroundPosterExtension); they loop with repeating animations and
// never use timers, so pausing for Reduce Motion freezes one still frame.

/// Renders a `ConversationBackground`. Set `background` (and `image` for a
/// photo, once decoded); the layer rebuilds on change and on resize.
public final class ConversationBackdropLayer: CALayer {
    /// The background to draw; nil draws nothing (the host's own color shows).
    public private(set) var background: ConversationBackground?
    /// The decoded photo of a `.photo` background.
    public private(set) var image: CGImage?

    /// Reduce Motion: dynamic backgrounds hold one still frame.
    public var isMotionPaused = false {
        didSet { if isMotionPaused != oldValue { applyMotion() } }
    }

    /// Increase Contrast: pushes the background away from the transcript's
    /// text color (darker under light text, lighter under dark text).
    public var increasesContrast = false {
        didSet { if increasesContrast != oldValue { applyContrast() } }
    }

    private let content = CALayer()
    private let scrim = CALayer()
    private var builtSize: CGSize = .zero

    public override init() {
        super.init()
        masksToBounds = true
        content.masksToBounds = true
        addSublayer(content)
        addSublayer(scrim)
        scrim.isHidden = true
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `background` (crossfading from the previous one when `animated`).
    public func set(_ background: ConversationBackground?, image: CGImage?, animated: Bool) {
        let sameLook = background?.id == self.background?.id && background?.kind == self.background?.kind
            && background?.colors == self.background?.colors && image === self.image
        self.background = background
        self.image = image
        guard !sameLook else { return }
        if animated, superlayer != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.35
            // On this layer, never on `content`: a paused (speed 0) content
            // layer would hold the transition at its first frame forever.
            add(fade, forKey: "backdrop.change")
        }
        rebuild()
        applyContrast()
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        scrim.frame = bounds
        CATransaction.commit()
        // Static kinds resize in place; dynamic ones are laid out for a size.
        if bounds.size != builtSize { rebuild() }
    }

    /// What is built, for lab logs.
    public var debugSummary: String {
        let first = content.sublayers?.first
        return "layers=\(content.sublayers?.count ?? 0) contents=\(first?.contents != nil) frame=\(first.map { "\($0.frame)" } ?? "-") speed=\(content.speed) hidden=\(isHidden) opacity=\(opacity) bounds=\(bounds.size)"
    }

    // MARK: Building

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
        content.contents = nil
        builtSize = bounds.size
        guard let background, bounds.width > 0, bounds.height > 0 else { return }
        let colors = background.colors.compactMap(Self.cgColor(hex:))
        switch background.kind {
        case .color:
            content.addSublayer(Self.gradient(colors.isEmpty ? [Self.gray] : colors, frame: bounds))
        case .photo:
            let photo = CALayer()
            photo.frame = bounds
            photo.contents = image
            photo.contentsGravity = .resizeAspectFill
            photo.masksToBounds = true
            // Until the image decodes, a neutral fill of the right luminance.
            photo.backgroundColor = Self.gray(luminance: background.luminance)
            content.addSublayer(photo)
        case .sky:
            buildSky(colors)
        case .water:
            buildWater(colors)
        case .aurora:
            buildAurora(colors)
        case .glitter:
            buildGlitter(colors)
        }
        applyMotion()
    }

    private var rng = SeededGenerator(seed: 1)

    private func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
        CGFloat.random(in: range, using: &rng)
    }

    /// Sky: the look's gradient with soft clouds drifting across, nearer ones faster.
    private func buildSky(_ colors: [CGColor]) {
        rng = SeededGenerator(seed: seed(for: "sky"))
        content.addSublayer(Self.gradient(colors.isEmpty ? [Self.gray] : colors, frame: bounds))
        let width = bounds.width
        let height = bounds.height
        let cloudColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        // Clouds keep a phone-sized scale on a large window; more of them fill it.
        let unit = min(width, 520)
        let count = min(24, max(7, Int((9 * width * height / (400 * 870)).rounded())))
        for index in 0..<count {
            let depth = CGFloat(index) / CGFloat(count - 1) // 0 far ... 1 near
            let size = CGSize(width: unit * (0.5 + 0.55 * depth), height: unit * (0.16 + 0.12 * depth))
            let cloud = CALayer()
            cloud.frame = CGRect(origin: .zero, size: size)
            for puff in 0..<5 {
                let blob = CAGradientLayer()
                blob.type = .radial
                let w = size.width * random(0.35...0.6)
                let h = size.height * random(0.7...1.1)
                blob.frame = CGRect(x: CGFloat(puff) / 5 * (size.width - w) + random(-10...10), y: (size.height - h) * random(0.2...0.8), width: w, height: h)
                blob.colors = [cloudColor.copy(alpha: 0.2 + 0.28 * depth)!, cloudColor.copy(alpha: 0)!]
                blob.startPoint = CGPoint(x: 0.5, y: 0.5)
                blob.endPoint = CGPoint(x: 1, y: 1)
                cloud.addSublayer(blob)
            }
            let y = height * random(0.04...0.92)
            cloud.position = CGPoint(x: random(0...width), y: y)
            let travel = width + size.width
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = -size.width / 2
            drift.toValue = width + size.width / 2
            drift.duration = Double(travel / (6 + 14 * depth)) // points per second
            drift.repeatCount = .infinity
            drift.timeOffset = drift.duration * Double(random(0...1))
            cloud.add(drift, forKey: "drift")
            content.addSublayer(cloud)
        }
    }

    /// Water: the look's depth gradient under slow, overlapping swells.
    private func buildWater(_ colors: [CGColor]) {
        rng = SeededGenerator(seed: seed(for: "water"))
        let base = colors.isEmpty ? [Self.gray] : colors
        content.addSublayer(Self.gradient(base, frame: bounds))
        let width = bounds.width
        let height = bounds.height
        for index in 0..<5 {
            let wavelength = width * (0.9 + 0.35 * CGFloat(index))
            let amplitude = height * (0.012 + 0.006 * CGFloat(index))
            let top = height * (0.18 + 0.16 * CGFloat(index))
            let path = CGMutablePath()
            let span = width + wavelength
            path.move(to: CGPoint(x: 0, y: height))
            var x: CGFloat = 0
            while x <= span {
                path.addLine(to: CGPoint(x: x, y: top + amplitude * sin(x / wavelength * 2 * .pi)))
                x += 6
            }
            path.addLine(to: CGPoint(x: span, y: height))
            path.closeSubpath()
            let wave = CAShapeLayer()
            wave.path = path
            wave.frame = CGRect(x: 0, y: 0, width: span, height: height)
            let light = index.isMultiple(of: 2)
            wave.fillColor = CGColor(srgbRed: light ? 1 : 0, green: light ? 1 : 0.1, blue: light ? 1 : 0.25, alpha: light ? 0.07 : 0.09)
            let roll = CABasicAnimation(keyPath: "position.x")
            roll.fromValue = span / 2
            roll.toValue = span / 2 - wavelength
            roll.duration = Double(7 + 3 * index)
            roll.repeatCount = .infinity
            roll.timeOffset = roll.duration * Double(random(0...1))
            wave.add(roll, forKey: "roll")
            let swell = CABasicAnimation(keyPath: "position.y")
            swell.fromValue = height / 2 - amplitude
            swell.toValue = height / 2 + amplitude
            swell.duration = Double(4 + index)
            swell.autoreverses = true
            swell.repeatCount = .infinity
            swell.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            wave.add(swell, forKey: "swell")
            content.addSublayer(wave)
        }
    }

    /// Aurora: glowing ribbons that sway and breathe over a night sky.
    private func buildAurora(_ colors: [CGColor]) {
        rng = SeededGenerator(seed: seed(for: "aurora"))
        let night = colors.first ?? Self.cgColor(hex: "#030914")!
        let deeper = Self.scaled(night, by: 0.6)
        content.addSublayer(Self.gradient([deeper, night, Self.scaled(night, by: 1.6)], frame: bounds))
        let glow = colors.count > 1 ? Array(colors.dropFirst()) : [Self.cgColor(hex: "#1FD89A")!]
        let width = bounds.width
        let height = bounds.height
        for index in 0..<6 {
            let color = glow[index % glow.count]
            let ribbon = CAGradientLayer()
            ribbon.type = .radial
            let w = width * random(0.9...1.5)
            let h = height * random(0.16...0.3)
            ribbon.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            ribbon.position = CGPoint(x: width * random(0.2...0.8), y: height * random(0.15...0.6))
            ribbon.colors = [color.copy(alpha: 0.75)!, color.copy(alpha: 0.25)!, color.copy(alpha: 0)!]
            ribbon.locations = [0, 0.45, 1]
            ribbon.startPoint = CGPoint(x: 0.5, y: 0.5)
            ribbon.endPoint = CGPoint(x: 1, y: 1)
            ribbon.transform = CATransform3DMakeRotation(random(-0.5...0.5), 0, 0, 1)
            let sway = CABasicAnimation(keyPath: "transform.rotation.z")
            let angle = random(-0.5...0.5)
            sway.fromValue = angle - 0.18
            sway.toValue = angle + 0.18
            sway.duration = Double(random(9...15))
            sway.autoreverses = true
            sway.repeatCount = .infinity
            sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sway.timeOffset = sway.duration * Double(random(0...1))
            ribbon.add(sway, forKey: "sway")
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = ribbon.position.x - width * 0.12
            drift.toValue = ribbon.position.x + width * 0.12
            drift.duration = Double(random(11...19))
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drift.timeOffset = drift.duration * Double(random(0...1))
            ribbon.add(drift, forKey: "drift")
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.35
            breathe.toValue = 1
            breathe.duration = Double(random(5...9))
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timeOffset = breathe.duration * Double(random(0...1))
            ribbon.add(breathe, forKey: "breathe")
            content.addSublayer(ribbon)
        }
        // A few stars above the glow.
        addSparkles(count: 40, colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)], size: 1.0...2.2, brightness: 0.3...0.8, twinkle: 2...5)
    }

    /// Glitter: a deep tint with a glow and many twinkling sparkles.
    private func buildGlitter(_ colors: [CGColor]) {
        rng = SeededGenerator(seed: seed(for: "glitter"))
        let deep = colors.first ?? Self.gray
        let tint = colors.count > 1 ? colors[1] : Self.scaled(deep, by: 3)
        content.addSublayer(Self.gradient([Self.scaled(deep, by: 1.5), deep, Self.scaled(deep, by: 0.6)], frame: bounds))
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = bounds.insetBy(dx: -bounds.width * 0.3, dy: -bounds.height * 0.1)
        glow.colors = [tint.copy(alpha: 0.45)!, tint.copy(alpha: 0)!]
        glow.startPoint = CGPoint(x: 0.5, y: 0.35)
        glow.endPoint = CGPoint(x: 1, y: 1)
        content.addSublayer(glow)
        let sparkle = colors.count > 2 ? [tint, colors[2]] : [tint, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)]
        let density = bounds.width * bounds.height / 1600
        addSparkles(count: Int(min(320, max(80, density))), colors: sparkle, size: 1.2...3.4, brightness: 0.2...1, twinkle: 0.8...2.6)
    }

    private func addSparkles(count: Int, colors: [CGColor], size: ClosedRange<CGFloat>, brightness: ClosedRange<CGFloat>, twinkle: ClosedRange<CGFloat>) {
        let field = CALayer()
        field.frame = bounds
        for index in 0..<count {
            let dot = CALayer()
            let side = random(size)
            dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            dot.cornerRadius = side / 2
            dot.position = CGPoint(x: random(0...bounds.width), y: random(0...bounds.height))
            dot.backgroundColor = colors[index % colors.count]
            dot.opacity = Float(random(brightness))
            let flicker = CABasicAnimation(keyPath: "opacity")
            flicker.fromValue = 0.05
            flicker.toValue = Float(brightness.upperBound)
            flicker.duration = Double(random(twinkle))
            flicker.autoreverses = true
            flicker.repeatCount = .infinity
            flicker.timeOffset = flicker.duration * Double(random(0...2))
            dot.add(flicker, forKey: "twinkle")
            field.addSublayer(dot)
        }
        content.addSublayer(field)
    }

    private func seed(for kind: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in ((background?.id ?? "") + kind).utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return hash
    }

    // MARK: Motion and contrast

    private func applyMotion() {
        // Pausing the container freezes every repeating animation at its
        // current phase (each starts at a random phase, so the still frame
        // looks like a moment of the loop, not its first frame).
        let paused = isMotionPaused || !(background?.kind.isDynamic ?? false)
        if paused, content.speed != 0 {
            content.timeOffset = content.convertTime(CACurrentMediaTime(), from: nil)
            content.speed = 0
        } else if !paused, content.speed == 0 {
            let pausedAt = content.timeOffset
            content.speed = 1
            content.timeOffset = 0
            content.beginTime = 0
            content.beginTime = content.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }

    private func applyContrast() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard increasesContrast, let background else {
            scrim.isHidden = true
            return
        }
        scrim.isHidden = false
        scrim.backgroundColor = background.prefersDarkContent
            ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)
    }

    // MARK: Colors

    static let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    /// A neutral gray whose relative luminance is `luminance`.
    static func gray(luminance: Double) -> CGColor {
        let l = min(1, max(0, luminance))
        let c = l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
        return CGColor(srgbRed: c, green: c, blue: c, alpha: 1)
    }

    public static func cgColor(hex: String) -> CGColor? {
        guard let (r, g, b) = ConversationBackground.rgb(hex: hex) else { return nil }
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static func scaled(_ color: CGColor, by factor: CGFloat) -> CGColor {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        let c = srgb.components ?? [0.5, 0.5, 0.5, 1]
        guard c.count >= 3 else { return color }
        return CGColor(srgbRed: min(1, c[0] * factor), green: min(1, c[1] * factor), blue: min(1, c[2] * factor), alpha: 1)
    }

    static func gradient(_ colors: [CGColor], frame: CGRect) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.frame = frame
        layer.colors = colors.count == 1 ? [colors[0], colors[0]] : colors
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        return layer
    }
}

/// SplitMix64: the same background lays out the same on every device.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
