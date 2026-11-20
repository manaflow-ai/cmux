import CmuxConversationGeometry
import CoreGraphics
import Testing

/// UIKit on iOS 26 starts a fling's deceleration a frame late: the frame
/// after the lift does not move and the next moves twice as far (iOS 26.5
/// simulator, ours and Messages alike: 27, 0, 51, 25 pt at 60 Hz; iOS 27
/// moves 27, 25, 25, 25). The fill draws the skipped frame's step.
@Suite struct ConversationDecelerationFillTests {
    /// Offsets UIKit 26 reports around a lift, one per 60 Hz update.
    static let stalled: [CGFloat] = [1000, 976, 949, 949, 898, 873.3, 849]

    @Test func aSkippedFrameIsDrawnAndTheDoubleStepCatchesUp() {
        var fill = ConversationDecelerationFill()
        var drawn: [CGFloat] = []
        for (i, offset) in Self.stalled.enumerated() {
            if i == 2 { fill.expectSkippedFrame() }
            let lead = fill.update(offset: offset, duration: 1.0 / 60, decelerating: i >= 2)
            drawn.append(offset + lead)
        }
        let steps = zip(drawn, drawn.dropFirst()).map { $1 - $0 }
        // Every drawn frame moves; none stalls and none jumps double.
        #expect(steps.allSatisfy { $0 < -20 && $0 > -30 })
        // Once the offset has caught up, the content is drawn at the offset.
        #expect(fill.lead == 0)
    }

    /// Nothing changes while the finger drags, while UIKit moves every
    /// frame, or once the deceleration ends.
    @Test func steadyMotionIsDrawnAsIs() {
        var fill = ConversationDecelerationFill()
        for (i, offset) in [1000, 975, 951, 928, 906].enumerated() {
            let lead = fill.update(offset: CGFloat(offset), duration: 1.0 / 120, decelerating: i > 0)
            #expect(lead == 0)
        }
        _ = fill.update(offset: 906, duration: 1.0 / 120, decelerating: true)
        let ended = fill.update(offset: 906, duration: 1.0 / 120, decelerating: false)
        #expect(ended == 0)
    }

    /// When the offset moves on without the double step, the drawn lead is
    /// absorbed over a few frames instead of snapping back.
    @Test func aLeadWithoutCatchUpFadesOut() {
        var fill = ConversationDecelerationFill()
        let offsets: [CGFloat] = [1000, 976, 952, 952, 928, 904, 880, 856, 832, 808, 784]
        var drawn: [CGFloat] = []
        for (i, offset) in offsets.enumerated() {
            if i == 1 { fill.expectSkippedFrame() }
            drawn.append(offset + fill.update(offset: offset, duration: 1.0 / 60, decelerating: i >= 1))
        }
        let steps = zip(drawn, drawn.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 < 0 && $0 >= -26 })
        #expect(abs(fill.lead) < 24)
    }

    /// A page landing mid-fling moves the offset by the inserted height to
    /// keep the rows in place, and UIKit's restarted deceleration skips that
    /// frame (iOS 27.0 simulator: 56, 54, 0, 103, 49 pt drawn). The shift is
    /// not motion; the skipped step is drawn.
    @Test func aPageLandingMidFlingIsNotAStall() {
        var fill = ConversationDecelerationFill()
        var drawn: [CGFloat] = []
        var shift: CGFloat = 0
        for (offset, landed) in [(CGFloat(1100), false), (1044, false), (990, false), (6958, true), (6855, false), (6806, false)] {
            if landed {
                fill.shift(by: 5968)
                shift += 5968
            }
            drawn.append(offset + fill.update(offset: offset, duration: 1.0 / 60, decelerating: true) - shift)
        }
        // No stalled frame and no double step (at 60 Hz the 54 pt skipped
        // step is drawn at the 40 pt bound and the rest paid back after).
        let steps = zip(drawn, drawn.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 <= -38 && $0 > -64 })
        #expect(fill.lead == 0)
    }

    /// Rows drawn past their frames leave a strip at the edge the content
    /// comes in from (only rows inside the bounds have cells), so a skipped
    /// frame is drawn at most `maximumLead` ahead.
    @Test func theLeadIsBoundedOnHardFlings() {
        var fill = ConversationDecelerationFill()
        fill.expectSkippedFrame()
        _ = fill.update(offset: 5000, duration: 1.0 / 120, decelerating: true, range: 0...10000)
        _ = fill.update(offset: 4900, duration: 1.0 / 120, decelerating: true, range: 0...10000)
        let lead = fill.update(offset: 4900, duration: 1.0 / 120, decelerating: true, range: 0...10000)
        #expect(lead == -ConversationDecelerationFill.maximumLead)
    }

    /// Near an edge UIKit bounces instead of carrying on, so nothing is
    /// predicted within a step of the scrollable range's ends (or past them).
    @Test func nothingIsPredictedIntoAnEdge() {
        var fill = ConversationDecelerationFill()
        fill.expectSkippedFrame()
        _ = fill.update(offset: 60, duration: 1.0 / 60, decelerating: true, range: 0...10000)
        _ = fill.update(offset: 36, duration: 1.0 / 60, decelerating: true, range: 0...10000)
        let lead = fill.update(offset: 36, duration: 1.0 / 60, decelerating: true, range: 0...10000)
        #expect(lead == 0)
    }

    /// When the motion turns (a bounce), a lead is absorbed, not dropped in
    /// one frame.
    @Test func aTurnAbsorbsTheLeadGradually() {
        var fill = ConversationDecelerationFill()
        fill.expectSkippedFrame()
        var drawn: [CGFloat] = []
        for offset in [CGFloat(1000), 976, 976, 990, 1004] {
            drawn.append(offset + fill.update(offset: offset, duration: 1.0 / 60, decelerating: true, range: 0...10000))
        }
        let steps = zip(drawn, drawn.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { abs($0) <= 24 })
    }

    /// An offset write the transcript did not report (a jump to the newest
    /// message) is not a fling: speeds past any fling's are not predicted.
    @Test func anImplausibleSpeedIsNotPredicted() {
        var fill = ConversationDecelerationFill()
        fill.expectSkippedFrame()
        _ = fill.update(offset: 1000, duration: 1.0 / 120, decelerating: true, range: 0...100000)
        _ = fill.update(offset: 9000, duration: 1.0 / 120, decelerating: true, range: 0...100000)
        let lead = fill.update(offset: 9000, duration: 1.0 / 120, decelerating: true, range: 0...100000)
        #expect(lead == 0)
    }

    /// A finger that catches a fling freezes the offset while UIKit still
    /// reports decelerating for a few frames. That is not a skipped frame:
    /// drawing ahead there and snapping back read as a vertical flicker on
    /// the phone (b02819d, iPhone 17 Pro Max: -25, -40, 0, 0, 0, 0, +40 pt).
    /// Only the frames UIKit is known to skip are drawn: right after the
    /// lift, and right after the transcript itself moved the offset.
    @Test func aCaughtFlingIsNotPredicted() {
        var fill = ConversationDecelerationFill()
        fill.expectSkippedFrame()
        var leads: [CGFloat] = []
        for offset in [CGFloat(2000), 1950, 1902, 1856, 1812, 1770, 1770, 1770, 1770] {
            leads.append(fill.update(offset: offset, duration: 1.0 / 120, decelerating: true, range: 0...10000))
        }
        #expect(leads.allSatisfy { $0 == 0 })
    }
}
