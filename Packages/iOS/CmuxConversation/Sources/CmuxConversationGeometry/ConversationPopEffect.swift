import CoreGraphics
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// The Undo Send "pop", shared by the iOS and macOS transcripts.
///
/// Messages plays ChatKit's `PopRendererView` (a Metal bulge, triangle
/// explosion, blur and matte choke) for 0.8 s inside the bubble's frame outset
/// by 100 pt. Rendering Apple's renderer offscreen for a 200x36 bubble shows:
/// for the first 30% the bubble swells linearly to about 1.18x; then it
/// shatters into small debris (about an eighth of the bubble's coverage) that
/// flies outward, decelerating and tumbling, to the clip edge by the end.
/// This reproduces that with Core Animation: a swelling snapshot, then
/// cropped pieces of it.
public enum ConversationPopEffect {
    /// `PopRendererView.duration`.
    public static let duration: CFTimeInterval = 0.8
    /// `PopRenderer.Parameters.popProgress`: the swell's share of the run.
    public static let swellFraction: Double = 0.3
    /// Measured swell at the moment the bubble breaks.
    public static let swellScale: CGFloat = 1.18
    /// `PopRendererView.frame(for:)` outsets the bubble by this much; debris
    /// outside it is clipped.
    public static let clipOutset: CGFloat = 100
    /// `explosionPieceSize`.
    public static let pieceSize: CGFloat = 6
    /// Reduce Motion: a plain fade instead.
    public static let reducedMotionDuration: CFTimeInterval = 0.25
    static let maxPieces = 420

    public struct Piece: Equatable, Sendable {
        /// Source rect in the snapshot, in points from its top-left corner.
        public var source: CGRect
        /// Travel by the end, in points (y down).
        public var displacement: CGVector
        /// Rotation by the end, in radians.
        public var rotation: CGFloat
        /// Debris size at the break, relative to the source piece.
        public var breakScale: CGFloat
        /// When the piece has faded out, as a fraction of `duration`.
        public var fadeEnd: Double
    }

    /// The debris plan for a bubble of `size` points. Deterministic per seed.
    public static func pieces(for size: CGSize, seed: UInt64) -> [Piece] {
        guard size.width > 0, size.height > 0 else { return [] }
        var edge = pieceSize
        while (size.width / edge).rounded(.up) * (size.height / edge).rounded(.up) > CGFloat(maxPieces) { edge += 1 }
        let columns = Int((size.width / edge).rounded(.up))
        let rows = Int((size.height / edge).rounded(.up))
        var random = SplitMix64(seed: seed)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Debris reaches the clip edge: about 240-300 pt/s measured, which
        // carries the outermost pieces past the 100 pt margin.
        let reach = clipOutset * 1.25
        var result: [Piece] = []
        result.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let source = CGRect(x: CGFloat(column) * edge, y: CGFloat(row) * edge, width: edge, height: edge)
                    .intersection(CGRect(origin: .zero, size: size))
                let offset = CGVector(dx: source.midX - center.x, dy: source.midY - center.y)
                // Radial, with up to pi/20 of jitter (initialDirectionRandomness).
                var angle = atan2(offset.dy, offset.dx)
                if offset.dx == 0, offset.dy == 0 { angle = random.unit * 2 * .pi }
                angle += (random.unit * 2 - 1) * .pi / 20 * 2
                // Outer pieces fly further (initialOuterTimeOffset), with
                // 30% speed randomness (initialVelocityRandomnessFactor).
                let outer = min(1, hypot(offset.dx / max(center.x, 1), offset.dy / max(center.y, 1)) / sqrt(2))
                let speed = reach * (0.35 + 0.65 * outer) * (1 + (random.unit * 2 - 1) * 0.3)
                let rotation = (random.unit < 0.5 ? -1 : 1) * 0.6 * .pi * CGFloat(duration * (1 - swellFraction)) * (0.5 + random.unit)
                result.append(Piece(
                    source: source,
                    displacement: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                    rotation: rotation,
                    breakScale: 0.35 + 0.25 * random.unit,
                    fadeEnd: 0.7 + 0.3 * Double(random.unit)
                ))
            }
        }
        return result
    }

    /// Plays the pop for `image` (a snapshot of the bubble) at `frame` in
    /// `host`'s coordinates, then removes its layers. `yUp` is true for a
    /// host with a bottom-left origin (an unflipped AppKit layer).
    @MainActor
    public static func play(
        image: CGImage,
        frame: CGRect,
        in host: CALayer,
        contentsScale: CGFloat,
        yUp: Bool,
        reduceMotion: Bool,
        seed: UInt64 = UInt64.random(in: .min ... .max),
        completion: (@MainActor () -> Void)? = nil
    ) {
        let clip = CALayer()
        clip.frame = frame.insetBy(dx: -clipOutset, dy: -clipOutset)
        clip.masksToBounds = true
        clip.contentsScale = contentsScale
        host.addSublayer(clip)
        // Bubble frame in the clip layer, and a y-down point mapper.
        let local = CGRect(x: clipOutset, y: clipOutset, width: frame.width, height: frame.height)
        func point(_ p: CGPoint) -> CGPoint {
            yUp ? CGPoint(x: p.x, y: clip.bounds.height - p.y) : p
        }

        let snapshot = CALayer()
        snapshot.contents = image
        snapshot.contentsScale = contentsScale
        snapshot.bounds = CGRect(origin: .zero, size: frame.size)
        snapshot.position = point(CGPoint(x: local.midX, y: local.midY))
        clip.addSublayer(snapshot)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            clip.removeFromSuperlayer()
            MainActor.assumeIsolated { completion?() }
        }
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = reducedMotionDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            snapshot.opacity = 0
            snapshot.add(fade, forKey: "pop")
            CATransaction.commit()
            return
        }

        let breakTime = duration * swellFraction
        let swell = CAKeyframeAnimation(keyPath: "transform.scale")
        swell.values = [1, swellScale, swellScale]
        swell.keyTimes = [0, NSNumber(value: swellFraction), 1]
        swell.duration = duration
        let vanish = CAKeyframeAnimation(keyPath: "opacity")
        vanish.values = [1, 1, 0, 0]
        vanish.keyTimes = [0, NSNumber(value: swellFraction - 0.001), NSNumber(value: swellFraction), 1]
        vanish.calculationMode = .discrete
        vanish.duration = duration
        let snapshotGroup = CAAnimationGroup()
        snapshotGroup.animations = [swell, vanish]
        snapshotGroup.duration = duration
        snapshot.opacity = 0
        snapshot.add(snapshotGroup, forKey: "pop")

        let pixelScale = CGFloat(image.width) / max(frame.width, 1)
        let start = CACurrentMediaTime() + breakTime
        let decelerate = CAMediaTimingFunction(controlPoints: 0.15, 0.7, 0.35, 1)
        let life = duration - breakTime
        for piece in pieces(for: frame.size, seed: seed) {
            let crop = CGRect(
                x: piece.source.minX * pixelScale, y: piece.source.minY * pixelScale,
                width: piece.source.width * pixelScale, height: piece.source.height * pixelScale
            ).integral
            guard let cropped = image.cropping(to: crop) else { continue }
            // Where the piece sits once the bubble has swelled.
            let home = CGPoint(
                x: local.midX + (piece.source.midX - frame.width / 2) * swellScale,
                y: local.midY + (piece.source.midY - frame.height / 2) * swellScale
            )
            let layer = CALayer()
            layer.contents = cropped
            layer.contentsScale = contentsScale
            layer.bounds = CGRect(origin: .zero, size: piece.source.size)
            layer.cornerRadius = piece.source.width / 3
            layer.masksToBounds = true
            layer.position = point(home)
            layer.opacity = 0
            clip.addSublayer(layer)

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = boxed(point(home))
            move.toValue = boxed(point(CGPoint(x: home.x + piece.displacement.dx, y: home.y + piece.displacement.dy)))
            move.timingFunction = decelerate
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = yUp ? -piece.rotation : piece.rotation
            spin.timingFunction = decelerate
            let shrink = CAKeyframeAnimation(keyPath: "transform.scale")
            shrink.values = [piece.breakScale * swellScale, piece.breakScale * 0.8]
            let fadeEnd = max(0.05, (piece.fadeEnd * duration - breakTime) / life)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, NSNumber(value: fadeEnd * 0.55), NSNumber(value: fadeEnd)]
            let group = CAAnimationGroup()
            group.animations = [move, spin, shrink, fade]
            group.beginTime = start
            group.duration = life
            group.fillMode = .both
            for animation in group.animations ?? [] { animation.duration = life }
            layer.add(group, forKey: "pop")
        }
        CATransaction.commit()
    }
}

private func boxed(_ point: CGPoint) -> NSValue {
    #if canImport(UIKit)
    NSValue(cgPoint: point)
    #else
    NSValue(point: point)
    #endif
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    var unit: CGFloat {
        mutating get { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    }
}
