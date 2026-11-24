#if os(iOS)
import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// The push measure (``PagedListPush``), as plain data: the rows' drawn move per frame, explained or not.
struct PagedListPushTests {
    /// A slide's steps: smooth, no push.
    @Test func aSmoothSlideIsNoPush() {
        #expect(PagedListPush.size(before: -16, move: -20, after: -24) == 0)
        #expect(PagedListPush.size(before: -6, move: -16, after: -20) == 0)
    }

    /// A 200 pt jump between two slide steps (video 8c0c85fb frame 574: +99 px between -13 and -20 px).
    @Test func aJumpBetweenSlideStepsIsAPush() {
        #expect(PagedListPush.size(before: -26, move: 198, after: -40) > 0)
    }

    /// The frame next to a push is not a push itself (it matches its other neighbour).
    @Test func theFramesAroundAPushAreNotPushes() {
        #expect(PagedListPush.size(before: -26, move: -26, after: 198) == 0)
        #expect(PagedListPush.size(before: 198, move: -40, after: -40) == 0)
    }

    /// A fling decelerating: large moves, changing smoothly.
    @Test func aFlingIsNoPush() {
        #expect(PagedListPush.size(before: 120, move: 108, after: 97) == 0)
    }

    /// Motion that starts and keeps going at that speed (a fling's first frame): the frame after
    /// matches it, so no push.
    @Test func motionThatStartsAndContinuesIsNoPush() {
        #expect(PagedListPush.size(before: 0, move: 60, after: 60) == 0)
    }

    /// A jump that stays where it lands (everything drawn 60 pt lower from one frame on): the moves
    /// are 0, 60, 0, so it is a push.
    @Test func aJumpThatStaysIsAPush() {
        #expect(PagedListPush.size(before: 0, move: 60, after: 0) == 60)
    }
}
#endif
