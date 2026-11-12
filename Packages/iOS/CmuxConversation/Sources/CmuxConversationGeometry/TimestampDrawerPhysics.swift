import CoreGraphics
import Foundation

/// Messages' swipe-left send-time drawer.
///
/// ChatKit drives the drawer from the transcript scroll view's own pan
/// (`CKTranscriptCollectionViewController collectionViewWillScroll:targetContentOffset:`,
/// identical in the iOS 26.5 and 27.0 simulator runtimes): the transcript
/// stays put until the finger has travelled 20 pt left of the last sample at
/// under 5 degrees from horizontal ("peeking"), then follows that overshoot
/// through the scroll view's rubber band and stops dead at the drawer width.
/// Vertical scrolling carries on underneath; a steeper drag only resamples.
///
/// On iOS 27 Messages needs 20 pt more travel before the drawer opens under
/// the same drags (offset curve otherwise identical, shifted by 20 pt), though
/// ChatKit's threshold is still 20: the 27 transcript peeks twice. Pass
/// `peekDistance: 40` there.
///
/// The rubber band and release were fitted to the simulator's Messages under
/// identical XCUITest drags on iOS 26.5 and 27.0 (same on both): offset
/// `d * (1 - 1 / (1 + c * x / d))` with c = 0.44, d = 600 (within 0.3 pt),
/// and on release a critically damped spring (omega 10.5 /s) whose start
/// velocity is the finger's minus 0.6 * omega * offset, clamped to the
/// drawer, so a fling waits at the stop before it falls back. A finger that
/// rested before lifting has no velocity, whatever the pan still reports
/// (fitted to a held release in the iOS 26.5 simulator).
public struct TimestampDrawerPhysics: Sendable, Equatable {
    /// ChatKit's finger travel past the last sample before the drawer opens.
    public static let chatKitPeekDistance: CGFloat = 20
    /// Measured on iOS 27 Messages: ChatKit's 20 pt, twice.
    public static let iOS27PeekDistance: CGFloat = 40
    /// Steepest drag, in degrees from horizontal, that opens the drawer.
    public static let peekMaxAngle: CGFloat = 5
    public static let rubberBandCoefficient: CGFloat = 0.44
    public static let rubberBandDimension: CGFloat = 600
    public static let releaseOmega: CGFloat = 10.5
    public static let releaseInwardVelocityFactor: CGFloat = 0.6
    /// A finger still this long before lifting releases at rest.
    public static let restingReleaseInterval: TimeInterval = 0.05
    /// Points left of zero below which a released drawer counts as closed.
    public static let restThreshold: CGFloat = 0.05

    /// The drawer is following the finger.
    public private(set) var isPeeking = false
    /// Pan translation at the last angle sample (ChatKit's `peekSampleTranslation`).
    public private(set) var sample: CGPoint = .zero
    /// How far the transcript is pulled left, 0...maxOffset.
    public private(set) var offset: CGFloat = 0
    public var maxOffset: CGFloat
    public var peekDistance: CGFloat

    public init(maxOffset: CGFloat, peekDistance: CGFloat = TimestampDrawerPhysics.chatKitPeekDistance) {
        self.maxOffset = maxOffset
        self.peekDistance = peekDistance
    }

    /// 0...1 of the drawer, as `drawerPercentRevealed`.
    public var fraction: CGFloat { maxOffset > 0 ? min(1, offset / maxOffset) : 0 }

    public static func rubberBand(_ overshoot: CGFloat) -> CGFloat {
        guard overshoot > 0 else { return 0 }
        let c = rubberBandCoefficient, d = rubberBandDimension
        return d * (1 - 1 / (1 + c * overshoot / d))
    }

    public static func inverseRubberBand(_ offset: CGFloat) -> CGFloat {
        guard offset > 0 else { return 0 }
        let c = rubberBandCoefficient, d = rubberBandDimension
        let ratio = min(offset / d, 0.999)
        return d / c * (1 / (1 - ratio) - 1)
    }

    /// Drawer width: the right margin plus the wider of 11:00 AM and 11:00 PM
    /// in the drawer font, as `transcriptDrawerWidthForMarginInsets:`.
    public static func drawerWidth(widestReferenceTime: CGFloat, margin: CGFloat) -> CGFloat {
        margin + widestReferenceTime.rounded(.up)
    }

    /// A drag begins. A drawer still open (settling back) is caught where it
    /// is, as a scroll view catches its own bounce.
    public mutating func begin(translation: CGPoint) {
        if offset > 0 {
            isPeeking = true
            sample = CGPoint(x: translation.x + peekDistance + Self.inverseRubberBand(offset), y: translation.y)
        } else {
            // ChatKit resets the sample to zero when a drag ends, so the first
            // drag measures from touch-down, slop included.
            isPeeking = false
            sample = .zero
        }
    }

    /// The drag moved; `translation` is the pan's translation in the transcript.
    public mutating func update(translation: CGPoint) {
        if !isPeeking {
            let dx = sample.x - translation.x
            guard dx >= peekDistance else {
                offset = 0
                return
            }
            let angle = abs(atan2(sample.y - translation.y, dx)) * 180 / .pi
            guard angle < Self.peekMaxAngle else {
                sample = translation
                offset = 0
                return
            }
            isPeeking = true
            // The overshoot counts from the 20 pt mark; this frame stays at 0.
            sample = CGPoint(x: translation.x + dx, y: translation.y)
            offset = 0
            return
        }
        let overshoot = sample.x - translation.x - peekDistance
        offset = min(max(0, Self.rubberBand(overshoot)), maxOffset)
    }

    /// The drag ended; `velocity` is the pan's, in points per second
    /// (negative = leftward), and `stillFor` how long the finger rested
    /// before lifting. Returns the release, or nil when already closed.
    public mutating func end(velocity: CGPoint, stillFor: TimeInterval = 0) -> Release? {
        isPeeking = false
        sample = .zero
        guard offset > 0 else { return nil }
        let outward = stillFor >= Self.restingReleaseInterval ? 0 : -velocity.x
        let v0 = outward - Self.releaseInwardVelocityFactor * Self.releaseOmega * offset
        return Release(start: offset, velocity: v0, maxOffset: maxOffset)
    }

    /// Applies a release sample; true once the drawer has closed.
    public mutating func settle(_ release: Release, elapsed: TimeInterval) -> Bool {
        let value = release.offset(at: elapsed)
        offset = value
        if value <= Self.restThreshold, elapsed > 0 {
            offset = 0
            return true
        }
        return false
    }

    /// A critically damped return to zero, clamped to the drawer.
    public struct Release: Sendable, Equatable {
        public var start: CGFloat
        public var velocity: CGFloat
        public var maxOffset: CGFloat

        public func offset(at t: TimeInterval) -> CGFloat {
            let w = TimestampDrawerPhysics.releaseOmega
            let time = CGFloat(max(0, t))
            let x = (start + (velocity + w * start) * time) * exp(-w * time)
            return min(max(0, x), maxOffset)
        }
    }
}

/// Where Messages draws a send time as its drawer opens (iOS 26.5 and 27.0
/// simulators): its frame waits at the transcript's trailing edge (the ink of
/// a tabular "1" starts 1.6 pt past it) and slides, 1.15x as fast as the
/// bubbles for this geometry, until the ink ends 17 pt inside the edge
/// (frame 16.4 pt). iOS 27 fades it in as the square of the reveal; iOS 26
/// draws it opaque.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum TimestampDrawerLabelGeometry {
    public static let restOutset: CGFloat = 0
    public static let trailingInset: CGFloat = 16.4

    public static func minX(width: CGFloat, labelWidth: CGFloat, fraction: CGFloat) -> CGFloat {
        let start = width + restOutset
        let end = width - trailingInset - labelWidth
        return start + (end - start) * fraction
    }

    public static func alpha(fraction: CGFloat, fadesIn: Bool) -> CGFloat {
        guard fraction > 0 else { return 0 }
        return fadesIn ? fraction * fraction : 1
    }
}

/// Which transcript rows the send-time drawer slides, and how far.
///
/// Measured in the iOS 26.5 and 27.0 simulators' Messages with incoming rows
/// fed in through a display-only `isFromMe` hook: in a one-to-one chat the
/// outgoing rows slide the full drawer and incoming rows stay put. In a group
/// transcript, whose incoming rows carry the avatar column, every row slides
/// together: avatars, sender names, quotes, reactions, attachments and the
/// typing bubble (the user's report from a real iPhone; ChatKit only gives
/// label rows the drawer layout when they use the contact-image layout).
/// Centered rows (dates, notices, system events) never move.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum TimestampDrawerRows {
    public static func travel(isOutgoing: Bool, inAvatarTranscript: Bool, reveal: CGFloat) -> CGFloat {
        isOutgoing || inAvatarTranscript ? reveal : 0
    }
}
