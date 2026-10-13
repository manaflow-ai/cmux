import CoreGraphics
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private func pointValue(_ point: CGPoint) -> NSValue {
    #if canImport(UIKit)
    NSValue(cgPoint: point)
    #else
    NSValue(point: point)
    #endif
}

// Messages "send with effect" animation, shared by the iOS and macOS
// surfaces. Everything here is Core Animation and Core Graphics only, in
// top-left-origin coordinates (UIKit, or a flipped AppKit view). Playback
// ends through animation completion, never through a timer.

/// The effects, by the raw values the conversation model uses.
public enum ConversationEffectAnimationKind: String, Sendable, CaseIterable {
    case slam
    case loud
    case gentle
    case invisibleInk
    case echo
    case spotlight
    case balloons
    case confetti
    case love
    case lasers
    case fireworks
    case celebration
}

// MARK: - Bubble effects

/// Keyframes for Slam, Loud and Gentle: transforms of the whole bubble about
/// its body center, with growth pinned to the sender-side edge so a swelling
/// bubble grows into the transcript instead of off screen.
public enum ConversationBubbleEffectAnimation {
    public static func duration(_ kind: ConversationEffectAnimationKind, reduceMotion: Bool) -> CFTimeInterval {
        switch kind {
        case .slam: return reduceMotion ? 0.3 : 0.85
        case .loud: return reduceMotion ? 0.3 : 1.55
        case .gentle: return reduceMotion ? 0.3 : 2.6
        default: return 0
        }
    }

    /// Fraction of the Slam duration at which the bubble hits its slot.
    public static let slamImpact: Double = 0.3

    /// The animation for a layer whose anchor is the bubble body center.
    /// `trailing` is true for my (right-aligned) bubbles.
    public static func make(_ kind: ConversationEffectAnimationKind, bubbleSize: CGSize, trailing: Bool, reduceMotion: Bool) -> CAAnimation? {
        let duration = duration(kind, reduceMotion: reduceMotion)
        guard duration > 0 else { return nil }
        if reduceMotion {
            // Reduce Motion: the effect becomes a plain fade-in.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = duration
            return fade
        }
        let shift = (trailing ? -1 : 1) * bubbleSize.width / 2
        func sc(_ s: CGFloat, dy: CGFloat) -> CATransform3D {
            CATransform3DScale(CATransform3DMakeTranslation(shift * (s - 1), dy, 0), s, s, 1)
        }
        let group = CAAnimationGroup()
        group.duration = duration
        group.fillMode = .backwards
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        switch kind {
        case .slam:
            // Large and lifted above its slot, it drops in a quarter second,
            // squashes on impact, and settles.
            let lift = -max(60, bubbleSize.height * 1.4)
            let transform = CAKeyframeAnimation(keyPath: "transform")
            let i = slamImpact
            transform.keyTimes = [0, NSNumber(value: i), NSNumber(value: i + 0.08), NSNumber(value: i + 0.2), NSNumber(value: i + 0.32), 1]
            transform.values = [sc(2.6, dy: lift), sc(1, dy: 0), sc(0.94, dy: 2), sc(1.03, dy: -1), sc(1, dy: 0), sc(1, dy: 0)]
                .map { NSValue(caTransform3D: $0) }
            transform.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.45),
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear),
            ]
            opacity.keyTimes = [0, 0.12, 1]
            opacity.values = [0, 1, 1]
            group.animations = [transform, opacity]
        case .loud:
            // Swells to almost twice its size, shouts (a fast rotational
            // shake), then shrinks back.
            let big = sc(1.9, dy: -bubbleSize.height * 0.45)
            var times: [NSNumber] = [0, 0.16]
            var values: [CATransform3D] = [sc(1, dy: 0), big]
            let shakes = 8
            for k in 0..<shakes {
                let t = 0.16 + 0.44 * Double(k + 1) / Double(shakes)
                let angle = (k % 2 == 0 ? 1.0 : -1.0) * 0.045 * (1 - Double(k) / Double(shakes + 2))
                times.append(NSNumber(value: t))
                values.append(CATransform3DRotate(big, CGFloat(angle), 0, 0, 1))
            }
            times.append(contentsOf: [0.62, 0.86, 1])
            values.append(contentsOf: [big, sc(1, dy: 0), sc(1, dy: 0)])
            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.keyTimes = times
            transform.values = values.map { NSValue(caTransform3D: $0) }
            transform.calculationMode = .cubic
            opacity.keyTimes = [0, 0.06, 1]
            opacity.values = [0, 1, 1]
            group.animations = [transform, opacity]
        case .gentle:
            // Appears small and quiet, holds, then slowly grows to size.
            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.keyTimes = [0, 0.22, 0.92, 1]
            transform.values = [sc(0.42, dy: 0), sc(0.45, dy: 0), sc(1.0, dy: 0), sc(1, dy: 0)].map { NSValue(caTransform3D: $0) }
            transform.timingFunctions = [
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1),
                CAMediaTimingFunction(name: .linear),
            ]
            opacity.keyTimes = [0, 0.12, 1]
            opacity.values = [0, 1, 1]
            group.animations = [transform, opacity]
        default:
            return nil
        }
        return group
    }

    /// An empty animation lasting until Slam's impact, for a completion hook.
    public static func slamImpactMarker() -> CAAnimation {
        let marker = CABasicAnimation(keyPath: "zPosition")
        marker.fromValue = 0
        marker.toValue = 0
        marker.duration = duration(.slam, reduceMotion: false) * slamImpact
        return marker
    }
}

// MARK: - Invisible Ink

public enum ConversationInkParticles {
    /// Fine dust: about one live particle per 9 square points.
    public static func birthRate(for size: CGSize) -> Float {
        Float(max(30, size.width * size.height / 14))
    }

    /// A configured emitter covering `size` (layer coordinates), particles in `color`.
    public static func configure(_ emitter: CAEmitterLayer, size: CGSize, color: CGColor, scale: CGFloat) {
        emitter.emitterShape = .rectangle
        emitter.emitterMode = .surface
        emitter.renderMode = .unordered
        emitter.emitterPosition = CGPoint(x: size.width / 2, y: size.height / 2)
        emitter.emitterSize = CGSize(width: max(1, size.width - 12), height: max(1, size.height - 8))
        let cell = CAEmitterCell()
        cell.contents = EffectImages.dot(scale: scale)
        cell.color = color
        cell.birthRate = birthRate(for: size)
        cell.lifetime = 1.6
        cell.lifetimeRange = 0.8
        cell.velocity = 4
        cell.velocityRange = 8
        cell.emissionRange = .pi * 2
        cell.scale = 0.14 * 3 / max(1, scale)
        cell.scaleRange = 0.08 * 3 / max(1, scale)
        cell.alphaRange = 0.6
        cell.alphaSpeed = -0.55
        emitter.emitterCells = [cell]
    }
}

// MARK: - Screen effects

/// Builds the eight full-screen effects as sublayers of a host layer.
@MainActor
public enum ConversationScreenEffect {
    public static func duration(_ kind: ConversationEffectAnimationKind) -> CFTimeInterval {
        switch kind {
        case .echo: return 3.6
        case .spotlight: return 3.6
        case .balloons: return 5.0
        case .confetti: return 4.6
        case .love: return 3.2
        case .lasers: return 4.4
        case .fireworks: return 4.6
        case .celebration: return 4.2
        default: return 0
        }
    }

    /// Plays `kind` once on `host` (top-left origin, `bounds` sized). `anchor`
    /// is the message bubble in host coordinates; `bubble` makes a copy of it
    /// (Echo). `completion` runs once, when the effect has finished.
    public static func play(
        _ kind: ConversationEffectAnimationKind,
        in host: CALayer,
        bounds: CGRect,
        anchor: CGRect,
        scale: CGFloat,
        bubble: (() -> CALayer?)? = nil,
        completion: @escaping @MainActor () -> Void
    ) {
        clear(host)
        let duration = duration(kind)
        guard duration > 0 else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        // A carrier animation fixes the playback length.
        let carrier = CABasicAnimation(keyPath: "zPosition")
        carrier.fromValue = 0
        carrier.toValue = 0
        carrier.duration = duration
        host.add(carrier, forKey: "screenEffect")
        let stage = Stage(host: host, bounds: bounds, scale: scale, duration: duration)
        switch kind {
        case .balloons: stage.balloons()
        case .confetti: stage.confetti()
        case .love: stage.love(anchor: anchor)
        case .lasers: stage.lasers(anchor: anchor)
        case .fireworks: stage.fireworks()
        case .celebration: stage.celebration()
        case .echo: stage.echo(anchor: anchor, bubble: bubble)
        case .spotlight: stage.spotlight(anchor: anchor)
        default: break
        }
        CATransaction.commit()
    }

    public static func isPlaying(_ host: CALayer) -> Bool {
        host.animation(forKey: "screenEffect") != nil
    }

    public static func clear(_ host: CALayer) {
        host.removeAnimation(forKey: "screenEffect")
        host.sublayers?.filter { $0.name == Stage.layerName }.forEach { $0.removeFromSuperlayer() }
    }

    static let palette: [CGColor] = [
        CGColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        CGColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),
        CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        CGColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),
        CGColor(srgbRed: 1.00, green: 0.18, blue: 0.57, alpha: 1),
    ]

    @MainActor
    struct Stage {
        static let layerName = "cmux.screenEffect"
        let host: CALayer
        let bounds: CGRect
        let scale: CGFloat
        let duration: CFTimeInterval

        private func add(_ layer: CALayer) {
            layer.name = Self.layerName
            host.addSublayer(layer)
        }

        private func dim(alpha: Float, fadeIn: CFTimeInterval = 0.35, fadeOut: CFTimeInterval = 0.5) {
            let dim = CALayer()
            dim.frame = bounds
            dim.backgroundColor = CGColor(gray: 0, alpha: 1)
            dim.opacity = 0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.keyTimes = [0, NSNumber(value: fadeIn / duration), NSNumber(value: 1 - fadeOut / duration), 1]
            fade.values = [0, alpha, alpha, 0]
            fade.duration = duration
            dim.add(fade, forKey: "dim")
            add(dim)
        }

        /// birthRate is a multiplier on every cell: 1 while emitting, then 0.
        private func burst(_ emitter: CAEmitterLayer, on: CFTimeInterval, off: CFTimeInterval, begin: CFTimeInterval = 0) {
            let total = duration - begin
            emitter.birthRate = 0
            let rate = CAKeyframeAnimation(keyPath: "birthRate")
            rate.keyTimes = [0, NSNumber(value: on / total), NSNumber(value: off / total), 1]
            rate.values = [0, 1, 0, 0]
            rate.calculationMode = .discrete
            rate.duration = total
            if begin > 0 { rate.beginTime = CACurrentMediaTime() + begin }
            rate.fillMode = .both
            emitter.add(rate, forKey: "burst")
        }

        func balloons() {
            var rng = SystemRandomNumberGenerator()
            let count = 12
            for index in 0..<count {
                let width = CGFloat.random(in: 64...86, using: &rng)
                let image = EffectImages.balloon(color: palette[index % palette.count], width: width, scale: scale)
                let size = CGSize(width: width, height: width * 2.3)
                let balloon = CALayer()
                balloon.contents = image
                balloon.contentsScale = scale
                balloon.bounds = CGRect(origin: .zero, size: size)
                let startX = CGFloat.random(in: 0.05...0.95, using: &rng) * bounds.width
                let startY = bounds.maxY + size.height / 2 + CGFloat.random(in: 0...160, using: &rng)
                let endY = -size.height
                balloon.position = CGPoint(x: startX, y: endY)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: startX, y: startY))
                let sway = CGFloat.random(in: 18...36, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                path.addCurve(
                    to: CGPoint(x: startX + sway * 0.5, y: endY),
                    control1: CGPoint(x: startX + sway, y: startY - (startY - endY) * 0.35),
                    control2: CGPoint(x: startX - sway, y: startY - (startY - endY) * 0.7)
                )
                let rise = CAKeyframeAnimation(keyPath: "position")
                rise.path = path
                let travel = CFTimeInterval.random(in: 3.0...3.9, using: &rng)
                rise.duration = travel
                rise.beginTime = CACurrentMediaTime() + CFTimeInterval(index) / CFTimeInterval(count) * (duration - travel - 0.1)
                rise.fillMode = .backwards
                rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.7, 1)
                balloon.add(rise, forKey: "rise")
                let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                wobble.values = [-0.08, 0.08, -0.08]
                wobble.duration = 1.6
                wobble.repeatCount = .infinity
                wobble.calculationMode = .cubic
                balloon.add(wobble, forKey: "wobble")
                add(balloon)
            }
        }

        func confetti() {
            let emitter = CAEmitterLayer()
            emitter.frame = bounds
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: -12)
            emitter.emitterSize = CGSize(width: bounds.width * 1.1, height: 1)
            emitter.renderMode = .oldestLast
            let shapes = [EffectImages.confettiRect(scale: scale), EffectImages.confettiCurl(scale: scale)]
            emitter.emitterCells = palette.flatMap { color in
                shapes.map { image -> CAEmitterCell in
                    let cell = CAEmitterCell()
                    cell.contents = image
                    cell.color = color
                    cell.birthRate = 7
                    cell.lifetime = 5
                    cell.velocity = 170
                    cell.velocityRange = 70
                    cell.yAcceleration = 120
                    cell.emissionLongitude = .pi
                    cell.emissionRange = .pi / 5
                    cell.spin = 3
                    cell.spinRange = 6
                    cell.scale = 0.55 * 3 / scale
                    cell.scaleRange = 0.25 * 3 / scale
                    return cell
                }
            }
            burst(emitter, on: 0, off: duration * 0.45)
            add(emitter)
        }

        func love(anchor: CGRect) {
            let size = min(bounds.width * 0.72, 300)
            let heart = CALayer()
            heart.contents = EffectImages.heart(size: size, scale: scale)
            heart.contentsScale = scale
            heart.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            let start = CGPoint(x: anchor.midX, y: anchor.minY)
            let rest = CGPoint(
                x: min(max(anchor.midX, size / 2 + 8), bounds.width - size / 2 - 8),
                y: max(size / 2 + 60, anchor.minY - size * 0.55)
            )
            heart.position = rest
            let position = CAKeyframeAnimation(keyPath: "position")
            position.keyTimes = [0, 0.25, 0.8, 1]
            position.values = [start, rest, rest, CGPoint(x: rest.x, y: rest.y - 40)].map(pointValue)
            // Inflates out of the bubble, beats twice, then deflates.
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.keyTimes = [0, 0.25, 0.35, 0.42, 0.52, 0.6, 0.8, 1]
            pulse.values = [0.08, 1.0, 1.12, 0.98, 1.12, 1.0, 1.0, 0.3]
            pulse.calculationMode = .cubic
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.keyTimes = [0, 0.1, 0.82, 1]
            opacity.values = [0, 1, 1, 0]
            let group = CAAnimationGroup()
            group.animations = [position, pulse, opacity]
            group.duration = duration
            heart.opacity = 0
            heart.add(group, forKey: "love")
            add(heart)
        }

        func lasers(anchor: CGRect) {
            dim(alpha: 0.88)
            let origin = CGPoint(x: anchor.midX, y: anchor.minY - 8)
            let colors = palette
            let beams = 7
            let length = hypot(bounds.width, bounds.height) * 1.2
            for index in 0..<beams {
                let beam = CAShapeLayer()
                let path = CGMutablePath()
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: 0, y: -length))
                beam.path = path
                beam.lineWidth = 3
                beam.lineCap = .round
                beam.strokeColor = colors[index % colors.count]
                beam.shadowColor = colors[index % colors.count]
                beam.shadowRadius = 8
                beam.shadowOpacity = 1
                beam.shadowOffset = .zero
                beam.position = origin
                beam.opacity = 0
                let base = (CGFloat(index) / CGFloat(beams - 1) - 0.5) * 1.6
                let sweep = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                sweep.values = [base - 0.5, base + 0.5, base - 0.5]
                sweep.duration = 1.4 + Double(index % 3) * 0.2
                sweep.repeatCount = .infinity
                sweep.calculationMode = .cubic
                beam.add(sweep, forKey: "sweep")
                let hue = CAKeyframeAnimation(keyPath: "strokeColor")
                hue.values = (0...colors.count).map { colors[($0 + index) % colors.count] }
                hue.duration = 1.2
                hue.repeatCount = .infinity
                beam.add(hue, forKey: "hue")
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.keyTimes = [0, 0.12, 0.85, 1]
                fade.values = [0, 1, 1, 0]
                fade.duration = duration
                beam.add(fade, forKey: "fade")
                add(beam)
            }
        }

        func fireworks() {
            dim(alpha: 0.82)
            var rng = SystemRandomNumberGenerator()
            let bursts = 5
            for index in 0..<bursts {
                let emitter = CAEmitterLayer()
                emitter.frame = bounds
                emitter.emitterShape = .point
                emitter.emitterPosition = CGPoint(
                    x: CGFloat.random(in: 0.2...0.8, using: &rng) * bounds.width,
                    y: CGFloat.random(in: 0.15...0.5, using: &rng) * bounds.height
                )
                emitter.renderMode = .additive
                let cell = CAEmitterCell()
                cell.contents = EffectImages.spark(scale: scale)
                cell.color = palette[(index * 2) % palette.count]
                cell.birthRate = 2600
                cell.lifetime = 1.7
                cell.lifetimeRange = 0.4
                cell.velocity = 210
                cell.velocityRange = 30
                cell.emissionRange = .pi * 2
                cell.yAcceleration = 70
                cell.alphaSpeed = -0.6
                cell.scale = 0.13 * 3 / scale
                cell.scaleSpeed = -0.05
                cell.greenRange = 0.2
                cell.redRange = 0.2
                emitter.emitterCells = [cell]
                burst(emitter, on: 0, off: 0.06, begin: 0.25 + Double(index) * (duration - 2.2) / Double(bursts))
                add(emitter)
            }
        }

        func celebration() {
            dim(alpha: 0.55)
            let emitter = CAEmitterLayer()
            emitter.frame = bounds
            emitter.emitterShape = .point
            emitter.emitterPosition = CGPoint(x: bounds.maxX + 10, y: -10)
            emitter.renderMode = .additive
            let gold = CAEmitterCell()
            gold.contents = EffectImages.spark(scale: scale)
            gold.color = CGColor(srgbRed: 1, green: 0.82, blue: 0.35, alpha: 1)
            gold.birthRate = 260
            gold.lifetime = 2.6
            gold.lifetimeRange = 0.8
            gold.velocity = 360
            gold.velocityRange = 160
            gold.emissionLongitude = .pi * 0.72
            gold.emissionRange = .pi / 7
            gold.alphaSpeed = -0.35
            gold.scale = 0.28 * 3 / scale
            gold.scaleRange = 0.18 * 3 / scale
            gold.redRange = 0.1
            gold.greenRange = 0.15
            emitter.emitterCells = [gold]
            burst(emitter, on: 0.2, off: duration * 0.6)
            add(emitter)
        }

        func echo(anchor: CGRect, bubble: (() -> CALayer?)?) {
            var rng = SystemRandomNumberGenerator()
            let copies = 22
            for index in 0..<copies {
                guard let copy = bubble?() else { return }
                let size = CGFloat.random(in: 0.55...1.05, using: &rng)
                let start = CGPoint(
                    x: CGFloat.random(in: 0.1...0.9, using: &rng) * bounds.width,
                    y: bounds.height * CGFloat.random(in: 0.35...1.05, using: &rng)
                )
                copy.position = start
                copy.opacity = 0
                let travel = CABasicAnimation(keyPath: "position")
                travel.fromValue = pointValue(start)
                travel.toValue = pointValue(CGPoint(
                    x: start.x + CGFloat.random(in: -30...30, using: &rng),
                    y: start.y - bounds.height * CGFloat.random(in: 0.45...0.8, using: &rng)
                ))
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.keyTimes = [0, 0.15, 0.75, 1]
                fade.values = [0, 1, 1, 0]
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = size * 0.6
                grow.toValue = size
                let group = CAAnimationGroup()
                group.animations = [travel, fade, grow]
                group.duration = 2.2
                group.beginTime = CACurrentMediaTime() + Double(index) / Double(copies) * (duration - 2.3)
                group.fillMode = .backwards
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                copy.add(group, forKey: "echo")
                add(copy)
            }
        }

        func spotlight(anchor: CGRect) {
            let shade = CAShapeLayer()
            shade.frame = bounds
            shade.fillRule = .evenOdd
            shade.fillColor = CGColor(gray: 0, alpha: 0.86)
            let radius = max(anchor.width, anchor.height) / 2 + 34
            let bounds = self.bounds
            func path(center: CGPoint, radius: CGFloat) -> CGPath {
                let p = CGMutablePath()
                p.addRect(bounds)
                p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                return p
            }
            let target = CGPoint(x: anchor.midX, y: anchor.midY)
            shade.path = path(center: target, radius: radius)
            let move = CAKeyframeAnimation(keyPath: "path")
            move.keyTimes = [0, 0.3, 1]
            move.values = [path(center: CGPoint(x: bounds.width * 0.25, y: bounds.height * 0.3), radius: radius * 1.2), path(center: target, radius: radius), path(center: target, radius: radius)]
            move.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .linear)]
            move.duration = duration
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.keyTimes = [0, 0.1, 0.85, 1]
            fade.values = [0, 1, 1, 0]
            fade.duration = duration
            shade.opacity = 0
            shade.add(move, forKey: "move")
            shade.add(fade, forKey: "fade")
            add(shade)
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.colors = [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.frame = CGRect(x: target.x - radius, y: target.y - radius, width: radius * 2, height: radius * 2)
            glow.opacity = 0
            glow.add(fade, forKey: "fade")
            add(glow)
        }
    }
}

// MARK: - Images

/// Particle and sprite images drawn with Core Graphics, top-left origin.
public enum EffectImages {
    /// Renders `size` points at `scale` with a top-left-origin context.
    public static func render(_ size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(context)
        return context.makeImage()
    }

    static func dot(scale: CGFloat) -> CGImage? {
        render(CGSize(width: 6, height: 6), scale: scale) { $0.setFillColor(CGColor(gray: 1, alpha: 1)); $0.fillEllipse(in: CGRect(x: 0, y: 0, width: 6, height: 6)) }
    }

    static func spark(scale: CGFloat) -> CGImage? {
        render(CGSize(width: 16, height: 16), scale: scale) { context in
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: 8, y: 8), startRadius: 0, endCenter: CGPoint(x: 8, y: 8), endRadius: 8, options: [])
        }
    }

    static func confettiRect(scale: CGFloat) -> CGImage? {
        render(CGSize(width: 12, height: 6), scale: scale) { $0.setFillColor(CGColor(gray: 1, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 12, height: 6)) }
    }

    static func confettiCurl(scale: CGFloat) -> CGImage? {
        render(CGSize(width: 14, height: 10), scale: scale) { context in
            context.move(to: CGPoint(x: 1, y: 8))
            context.addQuadCurve(to: CGPoint(x: 13, y: 2), control: CGPoint(x: 7, y: -2))
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.strokePath()
        }
    }

    static func balloon(color: CGColor, width: CGFloat, scale: CGFloat) -> CGImage? {
        let bodyHeight = width * 1.2
        let stringLength = width * 1.1
        let size = CGSize(width: width, height: bodyHeight + stringLength)
        let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [1, 0, 0, 1]
        func shade(_ f: CGFloat) -> CGColor { CGColor(srgbRed: min(1, rgb[0] * f), green: min(1, rgb[1] * f), blue: min(1, rgb[2] * f), alpha: 1) }
        let light = CGColor(srgbRed: min(1, rgb[0] * 0.8 + 0.25), green: min(1, rgb[1] * 0.8 + 0.25), blue: min(1, rgb[2] * 0.8 + 0.25), alpha: 1)
        let dark = shade(0.72)
        return render(size, scale: scale) { context in
            let body = CGRect(x: 0, y: 0, width: width, height: bodyHeight)
            context.saveGState()
            context.addEllipse(in: body)
            context.clip()
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [light, dark] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: width * 0.38, y: bodyHeight * 0.32), startRadius: 2, endCenter: CGPoint(x: width / 2, y: bodyHeight / 2), endRadius: width * 0.7, options: [.drawsAfterEndLocation])
            context.setFillColor(CGColor(gray: 1, alpha: 0.45))
            context.fillEllipse(in: CGRect(x: width * 0.22, y: bodyHeight * 0.14, width: width * 0.2, height: bodyHeight * 0.16))
            context.restoreGState()
            context.setFillColor(dark)
            context.move(to: CGPoint(x: width / 2 - 5, y: bodyHeight + 5))
            context.addLine(to: CGPoint(x: width / 2 + 5, y: bodyHeight + 5))
            context.addLine(to: CGPoint(x: width / 2, y: bodyHeight - 2))
            context.closePath()
            context.fillPath()
            context.move(to: CGPoint(x: width / 2, y: bodyHeight + 5))
            context.addCurve(to: CGPoint(x: width / 2, y: size.height), control1: CGPoint(x: width / 2 + 8, y: bodyHeight + stringLength * 0.35), control2: CGPoint(x: width / 2 - 8, y: bodyHeight + stringLength * 0.7))
            context.setStrokeColor(CGColor(gray: 0.55, alpha: 0.9))
            context.setLineWidth(1.2)
            context.strokePath()
        }
    }

    static func heart(size: CGFloat, scale: CGFloat) -> CGImage? {
        render(CGSize(width: size, height: size), scale: scale) { context in
            let w = size * 0.9, h = size * 0.82
            let x0 = (size - w) / 2, y0 = (size - h) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + x * w, y: y0 + y * h) }
            let heart = CGMutablePath()
            heart.move(to: p(0.5, 1))
            heart.addCurve(to: p(0, 0.32), control1: p(0.18, 0.78), control2: p(0, 0.58))
            heart.addCurve(to: p(0.5, 0.14), control1: p(0, 0.02), control2: p(0.4, -0.04))
            heart.addCurve(to: p(1, 0.32), control1: p(0.6, -0.04), control2: p(1, 0.02))
            heart.addCurve(to: p(0.5, 1), control1: p(1, 0.58), control2: p(0.82, 0.78))
            heart.closeSubpath()
            context.addPath(heart)
            context.setFillColor(CGColor(srgbRed: 1, green: 0.17, blue: 0.33, alpha: 1))
            context.fillPath()
            // A glossy highlight on the upper lobe.
            context.setFillColor(CGColor(gray: 1, alpha: 0.28))
            context.fillEllipse(in: CGRect(origin: p(0.14, 0.12), size: CGSize(width: w * 0.2, height: h * 0.15)))
        }
    }
}
