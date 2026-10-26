import AppKit
import CmuxNextChromiumWarmup
import CmuxNextWakeups
import Testing

/// Menu tracking comes from NSMenu's own notices (p06-scheduler-050): a window drag or a live
/// resize (the run loop's `eventTracking` mode with no menu) is not a menu, so the Chromium warmup
/// never waits for a menu end that does not come.
@MainActor struct MenuTrackingStateTests {
    let center = NotificationCenter()

    @Test func onlyAMenusBeginAndEndOfTrackingCount() {
        let state = MenuTrackingState(events: AppEvents(center: center))
        #expect(!state.isTracking, "no menu: a drag or a resize posts no menu notice")
        center.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        #expect(state.isTracking)
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(!state.isTracking)
    }

    /// The end observation calls its handler at each menu end until its token ends.
    @Test func theEndObservationLivesWithItsToken() {
        let state = MenuTrackingState(events: AppEvents(center: center))
        var ends = 0
        let token = state.observeEnd { ends += 1 }
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(ends == 1)
        (token as? EventSubscription)?.cancel()
        center.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(ends == 1, "an ended token stops the calls")
        #expect(!state.isTracking, "the state's own subscription still runs")
    }
}
