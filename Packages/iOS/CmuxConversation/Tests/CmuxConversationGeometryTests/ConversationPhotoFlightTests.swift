import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

@Suite struct ConversationPhotoFlightTests {
    @Test func springRunsFromZeroToOneMonotonically() {
        for omega in [ConversationPhotoFlight.openOmega, ConversationPhotoFlight.closeOmega] {
            #expect(ConversationPhotoFlight.progress(at: 0, omega: omega) == 0)
            #expect(ConversationPhotoFlight.progress(at: ConversationPhotoFlight.settleTime(omega: omega), omega: omega) == 1)
            var last: CGFloat = 0
            for frame in 1...40 {
                let p = ConversationPhotoFlight.progress(at: Double(frame) / 60, omega: omega)
                #expect(p >= last)
                #expect(p <= 1)
                last = p
            }
        }
    }

    /// iOS 26.5 simulator Messages (Quick Look), 60 fps: the photo's left
    /// edge as it flies between a 250 pt bubble and the full-width photo,
    /// measured from the frame the bubble hides.
    @Test func flightMatchesMessagesOpenAndClose() {
        let open = ConversationPhotoFlight.openOmega
        #expect(abs(ConversationPhotoFlight.progress(at: 0.075, omega: open) - 0.597) < 0.03)
        #expect(abs(ConversationPhotoFlight.progress(at: 0.144, omega: open) - 0.896) < 0.03)
        let close = ConversationPhotoFlight.closeOmega
        #expect(abs(ConversationPhotoFlight.progress(at: 0.093, omega: close) - 0.537) < 0.03)
        #expect(abs(ConversationPhotoFlight.progress(at: 0.177, omega: close) - 0.85) < 0.03)
        // The open lands in about a third of a second, the close in under half.
        #expect(ConversationPhotoFlight.settleTime(omega: open) < 0.36)
        #expect(ConversationPhotoFlight.settleTime(omega: close) < 0.5)
    }

    /// Messages' drag to dismiss (iOS 26.5): the photo shrinks linearly with
    /// the downward drag (0.93 at 92 pt, 0.865 at 176, 0.82 at 240) while a
    /// black veil over the transcript fades (0.77, 0.56, 0.40 opaque).
    @Test func dragShrinksPhotoAndFadesTheBlackVeilAsMessagesDoes() {
        #expect(abs(ConversationPhotoFlight.dragScale(translation: 92) - 0.93) < 0.01)
        #expect(abs(ConversationPhotoFlight.dragScale(translation: 176) - 0.865) < 0.01)
        #expect(abs(ConversationPhotoFlight.dragScale(translation: 240) - 0.82) < 0.01)
        #expect(abs(ConversationPhotoFlight.dragPresentation(translation: 92) - 0.77) < 0.02)
        #expect(abs(ConversationPhotoFlight.dragPresentation(translation: 176) - 0.56) < 0.02)
        #expect(abs(ConversationPhotoFlight.dragPresentation(translation: 240) - 0.40) < 0.02)
        // Dragging up neither grows the photo nor darkens past opaque.
        #expect(ConversationPhotoFlight.dragScale(translation: -50) == 1)
        #expect(ConversationPhotoFlight.dragPresentation(translation: -50) == 1)
        #expect(ConversationPhotoFlight.dragPresentation(translation: 900) == 0)
    }

    /// iOS 26 Messages opens a photo full screen on black with its chrome
    /// hidden (a tap shows it on the system background); iOS 27 opens with a
    /// close button and Share only, 16 pt in, 4 pt under the safe area.
    @Test func viewerChromePerOS() {
        #expect(ConversationPhotoViewerLayout.opensWithChromeHidden(.quickLook26))
        #expect(!ConversationPhotoViewerLayout.opensWithChromeHidden(.zoom27))
        #expect(ConversationPhotoViewerLayout.closeFrame(.zoom27, width: 440, safeTop: 62) == CGRect(x: 16, y: 66, width: 44, height: 44))
        #expect(ConversationPhotoViewerLayout.shareFrame(.zoom27, width: 440, safeTop: 62, bottom: 956) == CGRect(x: 380, y: 66, width: 44, height: 44))
        #expect(!ConversationPhotoViewerLayout.showsTitle(.zoom27))
        #expect(!ConversationPhotoViewerLayout.showsActions(.zoom27))
        #expect(ConversationPhotoViewerLayout.showsTitle(.quickLook26))
        #expect(ConversationPhotoViewerLayout.showsActions(.quickLook26))
        #expect(ConversationPhotoViewerLayout.closeFrame(.quickLook26, width: 402, safeTop: 62) == CGRect(x: 342, y: 62, width: 44, height: 44))
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

/// Letting go of a dragged photo, Messages' Quick Look flies it back from
/// the lift itself: one frame after the finger leaves, the photo has
/// already covered 17% of the way to its bubble (iOS 26.5, 60 fps, fitted
/// start within a frame of the lift). Ours started the spring at the first
/// frame of the dismissal transition, about 30 ms after the lift.
@Suite struct PhotoDragReleaseTimingTests {
    @Test func closeSpringStartsAtTheLift() {
        let lift: Double = 10.000
        let firstFrame: Double = 10.033
        let start = ConversationPhotoFlight.closeStart(lift: lift, firstFrame: firstFrame)
        #expect(start == lift)
        // One frame later the photo has left: 4.5% at omega 19.4 is visible.
        let p = ConversationPhotoFlight.progress(at: firstFrame + 1.0 / 60 - start, omega: ConversationPhotoFlight.closeOmega)
        #expect(p > 0.1)
    }

    @Test func closeButtonStartsAtTheFirstFrame() {
        #expect(ConversationPhotoFlight.closeStart(lift: nil, firstFrame: 5) == 5)
        // A stale lift (a drag that sprang back long before) is ignored.
        #expect(ConversationPhotoFlight.closeStart(lift: 1, firstFrame: 5) == 5)
    }
}
