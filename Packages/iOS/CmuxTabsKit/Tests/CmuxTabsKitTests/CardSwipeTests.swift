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

    /// Safari on one simulator, same AXe inputs (round 21): the 100 pt
    /// drag over 1 s that slows to a stop (about −70 pt/s at release)
    /// springs back; the 100 pt swipe over 1 s that leaves moving (about
    /// −190 pt/s) closes.
    @Test func slowStopSpringsBackMovingReleaseCloses() {
        for v: CGFloat in [0, -50, -66, -76, -100] {
            #expect(!CardSwipe.commits(offset: -100, velocity: v, cardWidth: w))
        }
        for v: CGFloat in [-170, -190, -200] {
            #expect(CardSwipe.commits(offset: -100, velocity: v, cardWidth: w))
        }
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

    /// Re-audit 2, D6b: a long press, then a drag left onto another slot,
    /// closed the dragged tab on the drop. The swipe never acts on a card
    /// a long press owns.
    @Test func longPressOwnsTheTouch() {
        #expect(!CardGestures.swipeAllowed(card: "a", pressed: "a", reordering: nil))
        #expect(!CardGestures.swipeAllowed(card: "a", pressed: nil, reordering: "a"))
        #expect(CardGestures.swipeAllowed(card: "a", pressed: nil, reordering: nil))
        #expect(CardGestures.swipeAllowed(card: "a", pressed: "b", reordering: nil))
    }

    /// Re-audit 2: a close tap during a reflow hit a card that had slid
    /// under the finger. Close taps wait for the grid to settle.
    @Test func closeTapsWaitForTheReflow() {
        #expect(!GridTapGuard.accepts(now: 10.2, changedAt: 10.0))
        #expect(GridTapGuard.accepts(now: 10.5, changedAt: 10.0))
    }
}
