import AppKit
import CmuxNextCompat
import Testing

/// Menu tracking comes from NSMenu's own notifications (p06-scheduler-050): a window drag or a live
/// resize (the run loop's `eventTracking` mode with no menu) is not a menu, so the Chromium warmup
/// never waits for a menu end that does not come.
@MainActor struct MenuTrackingStateTests {
    let center = NotificationCenter()

    @Test func onlyAMenusBeginAndEndOfTrackingCount() {
        let state = MenuTrackingState(center: center)
        #expect(!state.isTracking, "no menu: a drag or a resize posts no menu notification")
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        #expect(state.isTracking)
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(!state.isTracking)
    }

    /// The end observation calls its handler at each menu end until its token is released.
    @Test func theEndObservationLivesWithItsToken() {
        let state = MenuTrackingState(center: center)
        var ends = 0
        var token: AnyObject? = state.observeEnd { ends += 1 }
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(ends == 1)
        #expect(token != nil)
        token = nil
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(ends == 1, "a released token stops the calls")
    }
}
