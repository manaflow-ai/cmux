import AppKit
import CmuxNextCompat
import Testing

/// Menu tracking comes from NSMenu's own notices: a window drag or a live
/// resize (the run loop's `eventTracking` mode with no menu) is not a menu, so the Chromium warmup
/// never waits for a menu end that does not come.
@MainActor struct MenuTrackingStateTests {
    let center = NotificationCenter()

    @Test func onlyAMenusBeginAndEndOfTrackingCount() {
        let state = MenuTrackingState(center: center)
        let menu = NSMenu()
        #expect(!state.isTracking, "no menu: a drag or a resize posts no menu notice")
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(state.isTracking)
        #expect(state.tracked === menu)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(!state.isTracking)
        #expect(state.tracked == nil)
    }

    /// Each end reaches the live subscribers, after the state reads no menu; a released token stops
    /// its calls.
    @Test func theEndObservationLivesWithItsToken() {
        let state = MenuTrackingState(center: center)
        var ends: [Bool] = []
        var token: AnyObject? = state.observeEnd { [unowned state] in ends.append(state.isTracking) }
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(ends == [false])
        #expect(token != nil)
        token = nil
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(ends == [false], "a released token stops the calls")
    }
}
