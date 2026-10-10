import CoreGraphics
import Foundation

/// Messages' reply motion, read from ChatKit on iOS 26.5 and 27.0 (the two
/// agree on every value): `CKBalloonSwipeController` for swipe-to-reply,
/// `CKUIBehavior` for its thresholds, and the inline-reply layout dynamics of
/// `CKTranscriptCompositionalLayout` for the bubble's trip into the thread
/// and back.
public enum ConversationReplyMotion {
    // MARK: Swipe to reply

    /// `swipeToReplyConfirmThreshold`: past this the swipe commits.
    public static let confirmThreshold: CGFloat = 40
    /// `swipeToReplyShowIndicatorThreshold`: the arrow starts to appear here.
    public static let showIndicatorThreshold: CGFloat = 22
    /// A swipe only starts within 18 degrees of horizontal.
    public static let maximumSwipeAngle: CGFloat = 18
    /// `initialReplyIndicatorScale` / `finalReplyIndicatorScale` / `maxPulseReplyIndicatorScale`.
    public static let indicatorInitialScale: CGFloat = 0.4
    public static let indicatorFinalScale: CGFloat = 1
    public static let indicatorPulseScale: CGFloat = 1.15
    /// `initialReplyIndicatorBlurRadius`, faded to sharp as the arrow grows.
    public static let indicatorInitialBlurRadius: CGFloat = 4.5
    /// `replyToSelfButtonOffset`: an outgoing bubble's arrow drifts this far left.
    public static let outgoingIndicatorDrift: CGFloat = 12
    /// `replyIndicatorPulseAnimationDuration`; the haptic plays a quarter in.
    public static let pulseDuration: TimeInterval = 0.3
    /// `replyIndicatorResetAnimationDuration` (ease in-out) and
    /// `balloonResetAnimationDuration` (ease out).
    public static let indicatorResetDuration: TimeInterval = 0.4
    public static let bubbleResetDuration: TimeInterval = 0.25
    /// The touch must land on the bubble; narrow bubbles count as at least this wide.
    public static let minimumSwipeAreaWidth: CGFloat = 156
    /// An incoming bubble's swipe area starts this far in.
    public static let incomingSwipeAreaInset: CGFloat = 28

    /// How far the bubble follows a finger `translation` points to the right:
    /// 1:1 up to the threshold, then logarithmic (40 · (1 + 0.7 · log10(t / 40))).
    public static func bubbleOffset(forTranslation translation: CGFloat) -> CGFloat {
        guard translation >= confirmThreshold else { return max(0, translation) }
        return confirmThreshold * (1 + 0.7 * log10(translation / confirmThreshold))
    }

    /// The arrow's growth for a bubble `offset`: 0 until 22 pt, 1 at 40 pt.
    public static func indicatorProgress(forOffset offset: CGFloat) -> CGFloat {
        min(1, max(0, (offset - showIndicatorThreshold) / (confirmThreshold - showIndicatorThreshold)))
    }

    public static func indicatorScale(forProgress progress: CGFloat) -> CGFloat {
        indicatorInitialScale + (indicatorFinalScale - indicatorInitialScale) * progress
    }

    /// Left edge of the arrow's box: the bubble's leading edge on both sides.
    /// (ChatKit's arithmetic suggests an incoming arrow sits past the 6 pt
    /// tail; Messages on a device draws it at the edge.)
    public static func indicatorMinX(balloon: CGRect, isOutgoing: Bool) -> CGFloat {
        balloon.minX
    }

    /// Whether a pan with this velocity is horizontal enough to be a reply swipe.
    public static func isSwipeAngle(velocity: CGPoint) -> Bool {
        guard velocity.x != 0 else { return false }
        return abs(atan(velocity.y / velocity.x)) * 180 / .pi <= maximumSwipeAngle
    }

    /// The part of a bubble where a reply swipe may start (ChatKit's
    /// `_swipeToReplySafeSwipeRect`, left-to-right layout).
    public static func swipeArea(bubble: CGRect, isOutgoing: Bool) -> CGRect {
        var area = bubble
        if !isOutgoing { area.origin.x += incomingSwipeAreaInset }
        if area.width < minimumSwipeAreaWidth {
            let grow = minimumSwipeAreaWidth - area.width
            if isOutgoing { area.origin.x -= grow }
            area.size.width += grow
        }
        return area
    }

    // MARK: The trip into the thread and back

    /// `replyTranscriptBackgroundBlurAnimationTime`: the blur and the thread's
    /// fade, in and out, on UIKit's default ease in-out curve.
    public static let backgroundDuration: TimeInterval = 0.3

    /// The swiped bubble's horizontal offset as a share of the release offset,
    /// for `progress` (0...1) of its vertical trip: ChatKit's
    /// `curveValueForSwipeWithVelocity:t:`, the y of a cubic Bézier through
    /// (0,1), (0,1.5), (0.8,1), (1,0) evaluated at t. It swings about 20 %
    /// further out early on and is home when the bubble lands.
    public static func offsetCurve(progress t: CGFloat) -> CGFloat {
        let t = min(1, max(0, t))
        let u = 1 - t
        return u * u * u + 4.5 * t * u * u + 3 * t * t * u
    }

    /// Per-frame easing of one bubble in the thread's layout dynamics: items
    /// farther from the vertical middle get a lower value and move faster.
    /// `centerY` and `referenceY` (half the transcript height) are in the
    /// same space; `animatingOut` uses the quicker return values.
    public static func easing(centerY: CGFloat, itemHeight: CGFloat, referenceY: CGFloat, viewHeight: CGFloat, animatingOut: Bool) -> CGFloat {
        let near: CGFloat = animatingOut ? 0.84 : 0.89
        let far: CGFloat = animatingOut ? 0.775 : 0.825
        guard viewHeight > 0 else { return near }
        var total: CGFloat = 0
        for k in [-1, 0, 1] as [CGFloat] {
            let p = min(1, max(0, (abs(centerY - referenceY) + k * 0.5 * itemHeight) / viewHeight))
            let eased = 1 - (1 - p) * (1 - p) * (1 - p)
            total += near + (far - near) * eased
        }
        return total / 3
    }

    /// A thread row's easing for the whole trip, in or out. Messages fixes it
    /// from where the row sits in the thread (its slot, in window space) and
    /// paces it from the middle of the whole view, so a row covers the same
    /// share of what's left every frame: on an iPhone 17 Pro Max a 62 pt
    /// bubble whose slot is centred at y 530 covers 12.5 % per frame going
    /// in at every point of a 129 pt trip, and 16.9 % coming back.
    public static func threadEasing(slotCenterY: CGFloat, itemHeight: CGFloat, viewHeight: CGFloat, animatingOut: Bool) -> CGFloat {
        easing(centerY: slotCenterY, itemHeight: itemHeight, referenceY: viewHeight / 2, viewHeight: viewHeight, animatingOut: animatingOut)
    }

    /// The share of the remaining distance a bubble covers in a frame of
    /// `frameDuration` seconds (exact for 60 Hz, compounded for other rates).
    public static func step(easing: CGFloat, frameDuration: TimeInterval) -> CGFloat {
        let r = 1 - easing
        let n = CGFloat(max(frameDuration, 0) * 60)
        guard r < 1 else { return 1 }
        return min(1, r * (1 - pow(r, n)) / (1 - r))
    }

    /// When a bubble is this close to its slot it snaps there: 0.25 px going
    /// in, 2 px coming back (Messages lands a returning row from 0.68 pt).
    public static func snapDistance(scale: CGFloat, animatingOut: Bool) -> CGFloat {
        (animatingOut ? 2 : 0.25) / max(scale, 1)
    }

    /// Backing-transcript opacity while the thread is up: outgoing text
    /// bubbles 0.7, photos and attachments 0.4, everything else 1.
    public static let backingOutgoingTextAlpha: CGFloat = 0.7
    public static let backingAttachmentAlpha: CGFloat = 0.4
}

extension ConversationReplyMotion {
    /// Core Animation's ease in-out (cubic Bézier 0.42, 0, 0.58, 1) at `x`.
    public static func easeInOut(_ x: CGFloat) -> CGFloat {
        cubicBezierY(x: x, c1: CGPoint(x: 0.42, y: 0), c2: CGPoint(x: 0.58, y: 1))
    }

    /// y of the unit cubic Bézier through (0,0), `c1`, `c2`, (1,1) where its x is `x`.
    public static func cubicBezierY(x: CGFloat, c1: CGPoint, c2: CGPoint) -> CGFloat {
        let x = min(1, max(0, x))
        func coordinate(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var low: CGFloat = 0
        var high: CGFloat = 1
        var t = x
        for _ in 0..<40 {
            let value = coordinate(t, c1.x, c2.x)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return coordinate(t, c1.y, c2.y)
    }
}
