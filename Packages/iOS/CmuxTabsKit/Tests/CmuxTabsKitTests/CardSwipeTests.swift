@testable import CmuxTabsKit
import CoreGraphics
import Testing

/// Swipe-to-close, against Safari trials on the iPhone 17 Pro simulator
/// (177 pt cards): slow releases at -84, -105 and -123 pt sprang back, -132
/// and -140 closed; a 60 pt flick closed at 250 pt/s and above, not at 200.
struct CardSwipeTests {
    private let w: CGFloat = 177

    @Test func heldReleasesCloseOnlyPastSeventyTwoPercent() {
        for offset: CGFloat in [-84, -105, -123] {
            #expect(!CardSwipe.commits(offset: offset, velocity: 0, cardWidth: w))
        }
        for offset: CGFloat in [-132, -140] {
            #expect(CardSwipe.commits(offset: offset, velocity: 0, cardWidth: w))
        }
    }

    /// tabs-parity-audit 3e / 8a: Safari closed a 100 pt swipe over 1 s
    /// (card at −104.6 pt, still moving left).
    @Test func slowMovingSwipeCloses() {
        #expect(CardSwipe.commits(offset: -104.6, velocity: -100, cardWidth: w))
        #expect(!CardSwipe.commits(offset: -60, velocity: -100, cardWidth: w))
    }

    @Test func leftFlingsClose() {
        #expect(CardSwipe.commits(offset: -50, velocity: -250, cardWidth: w))
        #expect(CardSwipe.commits(offset: -50, velocity: -400, cardWidth: w))
        #expect(!CardSwipe.commits(offset: -50, velocity: -200, cardWidth: w))
    }

    @Test func rightNeverCloses() {
        #expect(!CardSwipe.commits(offset: 30, velocity: 900, cardWidth: w))
        // Dragged far left, then thrown back right.
        #expect(!CardSwipe.commits(offset: -140, velocity: 400, cardWidth: w))
    }

    @Test func leftTracksOneToOneRightIsRubberBanded() {
        #expect(CardSwipe.offset(translation: -90) == -90)
        // Safari: a 100 pt drag to the right (from touch-down) moved the card 44 pt.
        #expect(abs(CardSwipe.offset(translation: 100) - 44) < 1)
        #expect(CardSwipe.offset(translation: 400) < CardSwipe.rubberDimension)
    }
}
