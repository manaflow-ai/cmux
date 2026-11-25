import CmuxConversationGeometry
import CoreGraphics
import Testing

/// Where the open lays the transcript out once so every reuse queue gets
/// spare cells before live traffic needs one.
@Suite struct ConversationCellPoolWarmUpTests {
    @Test func layOutTwoScreensAboveTheResting() {
        #expect(ConversationCellPoolWarmUp.offset(restingY: 5000, topY: -150, viewport: 950) == 3100)
    }

    /// Less history than that: as high as it goes, still clear of the screen.
    @Test func clampsToTheTopOfLoadedHistory() {
        #expect(ConversationCellPoolWarmUp.offset(restingY: 1500, topY: -150, viewport: 950) == -150)
    }

    /// A screenful at the top would share rows with the one on screen:
    /// nothing would be queued, so it is skipped.
    @Test func skipsWhenHistoryIsShorterThanTwoScreens() {
        #expect(ConversationCellPoolWarmUp.offset(restingY: 700, topY: -150, viewport: 950) == nil)
    }
}
