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
}
