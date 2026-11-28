import CoreGraphics
import Foundation

/// The math of ChatKit's transcript dynamics (`CKTranscriptCompositionalLayout`,
/// read from the iOS 26.5 simulator runtime): Messages' rows do not move
/// rigidly with the scroll. A scroll step leaves every row where it was on
/// screen, and each displayed frame every row closes a share of the distance
/// to its place in the layout. The share depends on the row's easing, which
/// grows with its distance from the finger, so rows near the finger follow it
/// and rows a screen away trail by a few points.
///
/// - `applyDynamicScrollResistanceToItemsForScrollDeltaY:` holds rows on
///   screen when the offset changes.
/// - `prepareLayout`, driven by the update cycle after the display links
///   (`transcriptDynamics`), moves each row by
///   `(target - current) * step(easing, frame duration)` and snaps it home
///   within 0.25 px.
/// - `updateAttributesForAnchorYChangeWithAttributes:` (the drag's first
///   touch, `scrollViewWillBeginDragging:`) and
///   `updateAttributesForTargetContentOffsetChangeWithAttributes:` (a fling's
///   target, `scrollViewWillEndDragging:`) set each row's target easing; a row
///   adopts it once the content moves more than 2 pt in a frame.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationTranscriptDynamics {
    /// Which side a row sits on (`transcriptOrientation`).
    public enum Side: Sendable {
        case incoming
        case outgoing
        /// Timestamps, notices and other centered rows.
        case centered
    }

    /// The easing a row keeps at the finger: 0.01 incoming, 0.005 outgoing,
    /// 0 centered.
    public static func baseEasing(_ side: Side) -> Double {
        switch side {
        case .incoming: return 0.01
        case .outgoing: return 0.005
        case .centered: return 0
        }
    }

    /// A row adopts its target easing in a frame whose scroll step exceeds this.
    public static let easingAdoptionStep: CGFloat = 2
    /// Rows are placed on whole pixels in a frame whose scroll step exceeds this.
    public static let pixelRoundingStep: CGFloat = 2.5
    /// A row within this many pixels of its place snaps there.
    public static let snapPixels: CGFloat = 0.25

    /// The share of the remaining distance a row closes in a displayed frame
    /// of `duration` seconds at `easing`: the per-60 Hz-frame update
    /// `remaining *= easing` summed over the frame's length,
    /// `(1 - e) * (1 - (1 - e)^(60 * duration)) / e`, at most 1.
    public static func step(easing: Double, duration: Double) -> Double {
        guard easing > 0 else { return 1 }
        let keep = 1 - easing
        guard keep > 0 else { return 0 }
        let frames = max(0, duration) * 60
        return min(1, keep * (1 - pow(keep, frames)) / easing)
    }

    /// The target easing of a row whose center lies `centerDistance` from the
    /// finger's first touch, averaged over its top, center and bottom:
    /// `base + 0.75 * (1 - (1 - t)^3)` with `t` the distance over the viewport.
    public static func anchorEasing(base: Double, centerDistance: CGFloat, height: CGFloat, viewport: CGFloat) -> Double {
        guard viewport > 0 else { return base }
        var sum = 0.0
        for k in [-1.0, 0, 1] {
            let t = clamp01(Double(centerDistance) + k * Double(height) / 2, over: Double(viewport))
            sum += base + 0.75 * (1 - pow(1 - t, 3))
        }
        return sum / 3
    }

    /// When a fling sets its target, a row more than a viewport from the
    /// anchor trails further: `base + 0.75 + 0.15 * t^3`, `t` its distance
    /// past the viewport over `range` (see `flingRange`). Nil for a row
    /// within a viewport, which keeps its easing.
    public static func flingEasing(base: Double, centerDistance: CGFloat, height: CGFloat, viewport: CGFloat, range: CGFloat) -> Double? {
        guard centerDistance > viewport, range > 0 else { return nil }
        var sum = 0.0
        for k in [-1.0, 0, 1] {
            let t = clamp01(Double(centerDistance) + k * Double(height) / 2 - Double(viewport), over: Double(range))
            sum += base + 0.75 + 0.15 * t * t * t
        }
        return sum / 3
    }

    /// How far past the viewport the fling's far rows are spread over: the
    /// distance from the anchor to the target offset, at least half a viewport.
    public static func flingRange(anchorY: CGFloat, targetOffsetY: CGFloat, viewport: CGFloat) -> CGFloat {
        let span = targetOffsetY < anchorY ? anchorY - viewport - targetOffsetY : targetOffsetY - anchorY
        return max(viewport / 2, span)
    }

    /// Moves `current` toward `target` for one displayed frame, snapping it
    /// home when it comes within `snapPixels` (in points at `scale`).
    public static func advance(current: CGFloat, target: CGFloat, easing: Double, duration: Double, scale: CGFloat) -> CGFloat {
        let moved = current + (target - current) * CGFloat(step(easing: easing, duration: duration))
        return abs(moved - target) < snapPixels / max(1, scale) ? target : moved
    }

    private static func clamp01(_ value: Double, over length: Double) -> Double {
        min(1, max(0, value / length))
    }
}
