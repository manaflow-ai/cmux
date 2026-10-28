import CoreGraphics
import Foundation

/// UIKit on iOS 26 starts a fling's deceleration a frame late: the display
/// link it adds when the finger lifts does not fire in the next frame, so
/// that frame shows no movement and the one after moves twice as far (iOS
/// 26.5 simulator, ours and Messages alike: 27, 0, 51, 25 pt at 60 Hz; on
/// iOS 27 UIKit moves 27, 25, 25, 25). Setting the offset mid-fling (a page
/// landing above keeps the rows in place) restarts it the same way, on
/// iOS 27 too. A rigid transcript shows each stall; Messages' transcript
/// dynamics hide them.
///
/// This draws the content where the skipped frame's step would have taken
/// it (`lead`, in content-offset points along the motion) and lets the
/// next, double step catch the offset up, so every drawn frame moves.
/// Frames where UIKit moves are drawn as they are; a lead the offset does
/// not catch up is absorbed over a few frames rather than snapped back.
public struct ConversationDecelerationFill: Sendable, Equatable {
    /// How far ahead of the scroll offset the content is drawn.
    public private(set) var lead: CGFloat = 0
    private var lastOffset: CGFloat?
    /// UIKit's speed over its last step, in points per second.
    private var velocity: CGFloat = 0
    /// Time since UIKit last moved the offset.
    private var sinceMove: Double = 0
    /// Decelerating updates in which a frozen offset is a skipped frame.
    private var armed = 0

    /// A skipped frame is drawn only at fling speeds, where a stall shows.
    public static let minimumStep: CGFloat = 2
    /// Rows drawn past their frames leave a strip with no rows at the edge
    /// the content comes in from (only rows inside the bounds have cells),
    /// so the drawing leads by at most this much; the edges sit under the
    /// header's wash and the composer.
    public static let maximumLead: CGFloat = 40
    /// Faster than any fling: an offset write that was not reported.
    public static let maximumSpeed: CGFloat = 20_000
    /// Share of each step a leftover lead is absorbed by.
    static let absorption: CGFloat = 0.15
    /// Share of the lead kept per frame once the motion turns.
    static let turnDecay: CGFloat = 0.6
    /// UIKit skips the first or second frame after the lift (iOS 26.5
    /// simulator, 8 flings: 7 the first, 1 the second).
    static let skipWindow = 3

    public init() {}

    /// The finger lifted into a fling: UIKit is about to skip a frame.
    /// A frozen offset at any other time is not drawn ahead: a finger that
    /// catches a fling freezes it too while UIKit still reports
    /// decelerating, and drawing ahead there snapped back as a flicker.
    public mutating func expectSkippedFrame() {
        armed = Self.skipWindow
    }

    /// The offset was moved to keep the rows where they are (an older page
    /// landed above them): that move is not motion. UIKit restarts its
    /// deceleration when the offset is set, and skips the next frame then
    /// too, which the next update draws.
    public mutating func shift(by delta: CGFloat) {
        guard delta != 0 else { return }
        lastOffset = lastOffset.map { $0 + delta }
        armed = max(armed, 2)
    }

    /// One UI update after UIKit's display links: the offset this frame
    /// shows, the frame's length, whether UIKit is decelerating, and the
    /// offsets the content can rest at (`range`; UIKit bounces at its ends).
    /// Returns the lead to draw the content with.
    public mutating func update(offset: CGFloat, duration: Double, decelerating: Bool, range: ClosedRange<CGFloat>? = nil) -> CGFloat {
        defer { lastOffset = offset }
        guard decelerating, duration > 0, let previous = lastOffset else {
            lead = 0
            velocity = 0
            sinceMove = 0
            return lead
        }
        sinceMove += duration
        let step = offset - previous
        let frame = CGFloat(duration)
        let expectsSkip = armed > 0
        armed = max(0, armed - 1)
        if abs(step) < 0.01 {
            // UIKit skipped this frame: draw the step it would have taken,
            // unless it is not a fling's or would run into an edge.
            let predicted = velocity * frame
            guard expectsSkip, abs(predicted) > Self.minimumStep, abs(velocity) <= Self.maximumSpeed else { return lead }
            let target = lead + predicted
            if let range {
                let low = range.lowerBound + abs(predicted), high = range.upperBound - abs(predicted)
                guard low <= high, offset + target >= low, offset + target <= high else { return lead }
            }
            lead = min(Self.maximumLead, max(-Self.maximumLead, target))
            return lead
        }
        // UIKit's position follows time, so a step after a skipped frame
        // covers both frames: the speed is the step over the time since the
        // offset last moved, and this frame draws its share of it.
        let turned = velocity * step < 0
        velocity = step / CGFloat(sinceMove)
        sinceMove = 0
        if turned {
            // The motion turned (a bounce): bring the drawing back gently.
            lead *= Self.turnDecay
            return lead
        }
        // Draw this frame's share; a lead the bound cut short is paid back
        // over the next frames, a little each, rather than in one jump.
        let share = velocity * frame
        lead = min(Self.maximumLead, max(-Self.maximumLead, lead + share - step))
        let absorbed = min(abs(lead), Self.absorption * abs(share))
        lead -= lead < 0 ? -absorbed : absorbed
        return lead
    }
}
