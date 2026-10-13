import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// Reference values are `CKTranscriptCollectionViewController.balloonMaxWidth`
/// and `CKTextBalloonView` frames logged from Messages on iOS 26.5 and 27.0.
@Suite struct ConversationTranscriptMetricsTests {
    @Test func balloonMaxWidthMatchesChatKitOnPhones() {
        // iPhone 17 Pro: 402 pt, 16 pt margins.
        #expect(abs(ConversationTranscriptMetrics.balloonMaxWidth(betweenMargins: 370) - 280.6667) < 0.001)
        // iPhone 17 Pro Max: 440 pt, 20 pt margins.
        #expect(abs(ConversationTranscriptMetrics.balloonMaxWidth(betweenMargins: 400) - 310.6667) < 0.001)
    }

    @Test func balloonMaxWidthCapsAtEightyFivePercentWhenWide() {
        #expect(ConversationTranscriptMetrics.balloonMaxWidth(betweenMargins: 1000) == 850)
    }

    @Test func balloonSizesRoundUpToThePixelGrid() {
        func ceil3(_ v: CGFloat) -> CGFloat { ConversationTranscriptMetrics.ceilToPixel(v, scale: 3) }
        // Text widths + 28 pt pill insets, against Messages' balloon widths.
        #expect(abs(ceil3(249.70 + 28) - 278.0) < 0.001)
        #expect(abs(ceil3(182.61 + 28) - 210.6667) < 0.001)
        #expect(abs(ceil3(21.48 + 28) - 49.6667) < 0.001)
        #expect(abs(ceil3(246.02 + 28) - 274.3333) < 0.001)
        // One and five lines (20 pt pitch, the last line 20.287 pt) plus 10 pt
        // above and below.
        #expect(abs(ceil3(20.287 + 20) - 40.3333) < 0.001)
        #expect(abs(ceil3(4 * 20 + 20.287 + 20) - 120.3333) < 0.001)
        // Already on the grid: unchanged.
        #expect(abs(ceil3(278) - 278) < 0.0001)
    }

    @Test func outgoingGradientEndsAtTheRestingEntryView() {
        // CKChatController.gradientBottomPlaceholderHeight is 69 on both phones.
        #expect(ConversationTranscriptMetrics.gradientSpan(windowHeight: 874, bottomSafeInset: 34) == 805)
        #expect(ConversationTranscriptMetrics.gradientSpan(windowHeight: 956, bottomSafeInset: 34) == 887)
    }

    /// `CKUIBehavior` spaces and laid-out cell gaps from Messages on iOS 27.0
    /// (iPhone 17 Pro Max) at each text size; iOS 26.5 logs the same values.
    /// Caption line spacing (13, 18, 20, 22, 25, 29, 35, 41) for Large, XL,
    /// XXL, XXXL, AX1, AX2, AX3, AX4.
    @Test func spacesScaleWithTheCaptionLineSpacing() {
        func space(_ base: CGFloat, _ line: CGFloat) -> CGFloat {
            ConversationTranscriptMetrics.space(base, captionLineSpacing: line, scale: 3)
        }
        let lines: [CGFloat] = [13, 18, 20, 25, 29]
        let runs: [CGFloat] = [10, 14, 15.3333, 19.3333, 22.3333]
        let contiguous: [CGFloat] = [4, 5.6667, 6, 7.6667, 9]
        let small: [CGFloat] = [6, 8.3333, 9.3333, 11.6667, 13.3333]
        let mediumLarge: [CGFloat] = [16, 22, 24.6667, 30.6667, 35.6667]
        for (index, line) in lines.enumerated() {
            #expect(abs(space(10, line) - runs[index]) < 0.001)
            #expect(abs(space(4, line) - contiguous[index]) < 0.001)
            #expect(abs(space(6, line) - small[index]) < 0.001)
            #expect(abs(space(16, line) - mediumLarge[index]) < 0.001)
        }
        // XXXL (22), AX3 (35) and AX4 (41) between runs, in a run.
        #expect(abs(space(10, 22) - 17) < 0.001)
        #expect(abs(space(4, 22) - 6.6667) < 0.001)
        #expect(abs(space(10, 35) - 27) < 0.001)
        #expect(abs(space(4, 35) - 10.6667) < 0.001)
        #expect(abs(space(10, 41) - 31.6667) < 0.001)
        #expect(abs(space(4, 41) - 12.6667) < 0.001)
        // Smaller sizes keep the Large spaces (caption 2 stays 11 pt).
        #expect(space(10, 13) == 10)
    }

    /// Body to timestamp line box and line box to the next body, from the
    /// laid-out `CKTranscriptLabelCell` in Messages (iOS 27.0).
    @Test func timestampGapsFollowTheCaptionType() {
        let cases: [(line: CGFloat, size: CGFloat, above: CGFloat, below: CGFloat)] = [
            (13, 11, 13.6667, 7), (18, 13, 19, 11), (20, 15, 21, 12), (22, 17, 22.6667, 13),
            (25, 20, 26, 14.3333), (29, 24, 29.6667, 16.6667), (35, 29, 36, 20.3333),
        ]
        for c in cases {
            let above = ConversationTranscriptMetrics.timestampLineGap(captionLineSpacing: c.line, captionPointSize: c.size, scale: 3)
            let below = ConversationTranscriptMetrics.timestampFollowingGap(captionLineSpacing: c.line, captionPointSize: c.size, scale: 3)
            #expect(abs(above - c.above) < 0.01, "above \(c.size)")
            #expect(abs(below - c.below) < 0.01, "below \(c.size)")
        }
    }

    /// `CKTranscriptMultilineLabelCell` (the service header) to the first
    /// `CKTranscriptLabelCell` in Messages, iOS 27.0: 14.67 at Large, 21.67
    /// at XL, 23.67 at XXL, 25.67 at XXXL, 28.67 at AX1.
    @Test func headerToFirstTimestampFollowsTheCaptionType() {
        let cases: [(line: CGFloat, size: CGFloat, gap: CGFloat)] = [
            (13, 11, 14.6667), (18, 13, 21.6667), (20, 15, 23.6667), (22, 17, 25.6667), (25, 20, 28.6667),
        ]
        for c in cases {
            let gap = ConversationTranscriptMetrics.headerToTimestampGap(captionLineSpacing: c.line, captionPointSize: c.size, scale: 3)
            #expect(abs(gap - c.gap) < 0.01, "\(c.size)")
        }
    }
}
