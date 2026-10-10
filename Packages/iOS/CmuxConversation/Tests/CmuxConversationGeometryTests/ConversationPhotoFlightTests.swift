import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

@Suite struct ConversationPhotoFlightTests {
    @Test func springRunsFromZeroToOneMonotonically() {
        #expect(ConversationPhotoFlight.progress(at: 0) == 0)
        #expect(ConversationPhotoFlight.progress(at: ConversationPhotoFlight.settleTime) == 1)
        var last: CGFloat = 0
        for frame in 1...40 {
            let p = ConversationPhotoFlight.progress(at: Double(frame) / 60)
            #expect(p >= last)
            #expect(p <= 1)
            last = p
        }
        // Critically damped: most of the travel happens in the first half.
        #expect(ConversationPhotoFlight.progress(at: ConversationPhotoFlight.settleTime / 2) > 0.7)
    }

    @Test func outlineIsSquareFullScreenAndTheBubbleAtFullRadius() {
        let rect = CGRect(x: 0, y: 0, width: 260, height: 200)
        // Full screen: a plain rectangle, so no corner ever shows rounded there.
        #expect(ConversationPhotoFlight.outline(in: rect, radius: 0, side: .trailing, tailed: true).boundingBox == rect)
        // At the bubble: the tail drops into the reserved strip below the body.
        let radius: CGFloat = 20.1435546875
        let bubble = ConversationPhotoFlight.outline(in: rect, radius: radius, side: .trailing, tailed: true)
        let body = CGRect(x: 0, y: 0, width: 260, height: 200 - ConversationBubbleGeometry.iOSTailDrop(radius: radius))
        let expected = ConversationBubbleGeometry.iOSPath(in: body, side: .trailing, tail: true, radius: radius)
        #expect(bubble.boundingBox.integral == expected.boundingBox.integral)
        #expect(abs(bubble.boundingBox.maxY - rect.maxY) < 1)
        // A rounded corner leaves the frame's corner outside the outline.
        #expect(!bubble.contains(CGPoint(x: 1, y: 1)))
        #expect(bubble.contains(CGPoint(x: 130, y: 100)))
    }

    @Test func cornersGrowContinuously() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 220)
        var previousCut: CGFloat = 0
        for step in 1...10 {
            let r = 20 * CGFloat(step) / 10
            let path = ConversationPhotoFlight.outline(in: rect, radius: r, side: .leading, tailed: false)
            // How far along the top edge the corner starts.
            var cut: CGFloat = 0
            while cut < 60, !path.contains(CGPoint(x: cut + 0.5, y: 0.5)) { cut += 0.5 }
            #expect(cut >= previousCut)
            previousCut = cut
        }
        #expect(previousCut > 4)
    }
}
