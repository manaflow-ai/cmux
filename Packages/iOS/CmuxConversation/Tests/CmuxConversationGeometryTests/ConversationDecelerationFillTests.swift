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
            drawn.append(offset + fill.update(offset: offset, duration: 1.0 / 60, decelerating: i >= 1))
        }
        let steps = zip(drawn, drawn.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 < 0 && $0 >= -26 })
        #expect(abs(fill.lead) < 24)
    }
}
