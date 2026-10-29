@testable import CmuxNextSidebar
import Testing

/// `ProfileSwipeTracker`, the one-step space swipe that `SidebarSwipeFeed` feeds from the input tap:
/// one switch per gesture past the threshold, only for a mostly horizontal gesture, and a gesture
/// is horizontal only while it lasts (its end and its momentum go on to the scroll view).
struct ProfileSwipeTrackerTests {
    @Test func aHorizontalGesturePastTheThresholdSwitchesOnce() {
        var tracker = ProfileSwipeTracker()
        #expect(tracker.feed(deltaX: 30, deltaY: 0, phase: .began) == nil)
        #expect(tracker.feed(deltaX: 40, deltaY: 0, phase: .changed) == -1, "a rightward swipe goes to the previous space")
        #expect(tracker.feed(deltaX: 80, deltaY: 0, phase: .changed) == nil, "one switch per gesture")
        #expect(tracker.isHorizontal)
    }

    @Test func aMostlyVerticalGestureNeverSwitchesAndIsNotHorizontal() {
        var tracker = ProfileSwipeTracker()
        _ = tracker.feed(deltaX: 50, deltaY: 40, phase: .began)
        #expect(tracker.feed(deltaX: 40, deltaY: 40, phase: .changed) == nil)
        #expect(!tracker.isHorizontal)
    }

    @Test func aGestureIsHorizontalOnlyUntilItsEnd() {
        var tracker = ProfileSwipeTracker()
        _ = tracker.feed(deltaX: -30, deltaY: 0, phase: .began)
        #expect(tracker.isHorizontal)
        #expect(tracker.feed(deltaX: 0, deltaY: 0, phase: .ended) == nil)
        #expect(!tracker.isHorizontal, "a gesture's end scrolls as before")
        #expect(tracker.feed(deltaX: -90, deltaY: 0, phase: .momentum) == nil, "momentum never switches")
        #expect(tracker.feed(deltaX: -90, deltaY: 0, phase: .changed) == nil, "a change after the end is no new gesture")
    }

    @Test func aNewGestureCanSwitchAgain() {
        var tracker = ProfileSwipeTracker()
        _ = tracker.feed(deltaX: -70, deltaY: 0, phase: .began)
        _ = tracker.feed(deltaX: 0, deltaY: 0, phase: .ended)
        #expect(tracker.feed(deltaX: -70, deltaY: 0, phase: .began) == 1, "a leftward swipe goes to the next space")
    }
}
