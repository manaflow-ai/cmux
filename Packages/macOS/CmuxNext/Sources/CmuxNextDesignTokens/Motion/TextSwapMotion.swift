public import Foundation

/// The one text swap of cmux NEXT, as numbers: words that change in place (the agent chat's live
/// line naming the call in flight, a sidebar workspace's name an agent changed) leave and arrive the
/// same way on the web (`useTextSwap.ts`) and in the app (`MotionGate.swapText`). Leo 2026-11-08:
/// "when workspaces get renamed (esp by agents) it should have that same fade in animation that the
/// tool call situation has".
///
/// - The old words rise `MotionScale.textSwapRise` points and fade out, gone at
///   `textSwapGoneAt` of `micro`.
/// - The new words rise in from `textSwapRise` points below over `standard`, unseen until
///   `textSwapShowFrom` of it, so no two texts read over each other.
/// - Both ease out (`MotionScale.easeOut`) over the whole animation; the keyframes between run
///   linearly in that eased time, as Web Animations runs an effect-wide easing.
/// - Reduce Motion (or a live resize): a crossfade with nothing moving, at most one `crossfade`
///   long (`MotionPolicy.duration`'s ceiling). Motion off or fades off: no motion (`init` is nil).
///
/// Pure, so the timing is tested without AppKit and a gallery can pose any instant of it.
public nonisolated struct TextSwapMotion: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// The old words rise out and the new ones rise in.
        case rise
        /// Reduce Motion: the old words fade out over the new ones fading in; nothing moves.
        case crossfade
    }

    public var style: Style
    /// Seconds the old words take to go.
    public var outDuration: TimeInterval
    /// Seconds the new words take to arrive.
    public var inDuration: TimeInterval

    /// How far the words rise, in points.
    public static var rise: Double { MotionScale.textSwapRise }
    /// The old words are gone by this fraction of `outDuration`.
    public static var goneAt: Double { MotionScale.textSwapGoneAt }
    /// The new words stay unseen up to this fraction of `inDuration`.
    public static var showFrom: Double { MotionScale.textSwapShowFrom }

    public init(style: Style, outDuration: TimeInterval, inDuration: TimeInterval) {
        self.style = style
        self.outDuration = outDuration
        self.inDuration = inDuration
    }

    /// The swap `policy` allows; nil when the words change in one frame (motion or the category off).
    public init?(policy: MotionPolicy) {
        guard policy.animatesFades else { return nil }
        let scale = policy.speed.timeScale
        if policy.animatesMovement {
            self.init(style: .rise, outDuration: MotionScale.micro * scale, inDuration: MotionScale.standard * scale)
        } else {
            let fade = min(MotionScale.micro * scale, MotionFade.crossfade.baseDuration)
            guard fade > 0 else { return nil }
            self.init(style: .crossfade, outDuration: fade, inDuration: fade)
        }
    }

    /// Where a layer of words stands: its opacity and its offset in points, down positive (CSS `translateY`).
    public struct Pose: Sendable, Equatable {
        public var opacity: Double
        public var y: Double

        public init(opacity: Double, y: Double) {
            self.opacity = opacity
            self.y = y
        }
    }

    /// The old words `time` seconds into the swap, leaving from `start` (where they stood when it began: at rest,
    /// or partway in from an earlier swap).
    public func outgoing(at time: TimeInterval, from start: Pose = Pose(opacity: 1, y: 0)) -> Pose {
        let progress = Self.ease(outDuration > 0 ? time / outDuration : 1)
        switch style {
        case .rise:
            let fade = min(progress / Self.goneAt, 1)
            return Pose(opacity: start.opacity * (1 - fade), y: start.y + (-Self.rise - start.y) * progress)
        case .crossfade:
            return Pose(opacity: start.opacity * (1 - progress), y: start.y)
        }
    }

    /// The new words `time` seconds into the swap.
    public func incoming(at time: TimeInterval) -> Pose {
        let progress = Self.ease(inDuration > 0 ? time / inDuration : 1)
        switch style {
        case .rise:
            let shown = progress <= Self.showFrom ? 0 : (progress - Self.showFrom) / (1 - Self.showFrom)
            return Pose(opacity: shown, y: Self.rise * (1 - progress))
        case .crossfade:
            return Pose(opacity: progress, y: 0)
        }
    }

    /// `MotionScale.easeOut` at linear time `t` in 0...1.
    public static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        let (x1, y1, x2, y2) = (Double(MotionScale.easeOut.0), Double(MotionScale.easeOut.1),
                                Double(MotionScale.easeOut.2), Double(MotionScale.easeOut.3))
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        // x(s) is monotonic for a timing function: bisect for x(s) = t, then read y(s).
        var low = 0.0, high = 1.0, s = t
        for _ in 0..<40 {
            let x = bezier(s, x1, x2)
            if abs(x - t) < 1e-7 { break }
            if x < t { low = s } else { high = s }
            s = (low + high) / 2
        }
        return bezier(s, y1, y2)
    }
}
