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

    /// A skipped frame is drawn only at fling speeds, where a stall shows.
    public static let minimumStep: CGFloat = 2
    /// Share of each step a leftover lead is absorbed by.
    static let absorption: CGFloat = 0.15

    public init() {}

    /// The offset was moved to keep the rows where they are (an older page
    /// landed above them): that move is not motion. UIKit restarts its
    /// deceleration when the offset is set, and skips the next frame then
    /// too, which the next update draws.
    public mutating func shift(by delta: CGFloat) {
        lastOffset = lastOffset.map { $0 + delta }
    }

    /// One UI update after UIKit's display links: the offset this frame
    /// shows, the frame's length, and whether UIKit is decelerating.
    /// Returns the lead to draw the content with.
    public mutating func update(offset: CGFloat, duration: Double, decelerating: Bool) -> CGFloat {
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
        if abs(step) < 0.01 {
            // UIKit skipped this frame: draw the step it would have taken.
            if abs(velocity) * frame > Self.minimumStep { lead += velocity * frame }
            return lead
        }
        // UIKit's position follows time, so a step after a skipped frame
        // covers both frames: the speed is the step over the time since the
        // offset last moved, and this frame draws its share of it.
        velocity = step / CGFloat(sinceMove)
        sinceMove = 0
        lead += velocity * frame - step
        // Never draw behind the motion; absorb what is left over a few frames.
        if lead * step < 0 { lead = 0 }
        let absorbed = min(abs(lead), Self.absorption * abs(step))
        lead -= lead < 0 ? -absorbed : absorbed
        return lead
    }
}
