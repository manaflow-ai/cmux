@testable import CmuxNextDaemonService
import Testing

/// A chat clicked while this Mac's sessions restore waits and opens once they are ready (Leo, 2026-11-08: "me trying
/// to click into any other chat in the sidebar doesn't work"): one open at a time, the newest click wins, and it is
/// dropped when its window closed or after ten minutes (`PendingOpenSlot`, run by `PendingSessionOpen`).
@MainActor
struct PendingOpenSlotTests {
    private let start = ContinuousClock.now

    @Test func theLatestClickRunsOnceTheSessionsAreReady() {
        var slot = PendingOpenSlot<String>()
        let replacedNone = slot.hold("chat-a", at: start)
        let replacedFirst = slot.hold("chat-b", at: start + .seconds(5))
        #expect(!replacedNone)
        #expect(replacedFirst, "a newer click did not replace the waiting one")
        let early = slot.step(ready: false, windowOpen: true, now: start + .seconds(60))
        #expect(early == nil)
        #expect(slot.isWaiting)
        let ready = slot.step(ready: true, windowOpen: true, now: start + .seconds(90))
        #expect(ready == .run("chat-b"))
        #expect(!slot.isWaiting)
        let again = slot.step(ready: true, windowOpen: true, now: start + .seconds(91))
        #expect(again == nil, "the open ran twice")
    }

    @Test func itIsDroppedAfterTenMinutesOrWhenItsWindowClosed() {
        var slot = PendingOpenSlot<String>()
        slot.hold("chat", at: start)
        let before = slot.step(ready: false, windowOpen: true, now: start + PendingOpenPatience.limit - .seconds(1))
        let expired = slot.step(ready: false, windowOpen: true, now: start + PendingOpenPatience.limit)
        #expect(before == nil)
        #expect(expired == .drop("chat"))
        #expect(!slot.isWaiting)

        slot.hold("chat", at: start)
        let closed = slot.step(ready: true, windowOpen: false, now: start + .seconds(1))
        #expect(closed == .drop("chat"), "an open whose window closed ran in another")

        // A newer click restarts the ten minutes.
        slot.hold("first", at: start)
        slot.hold("second", at: start + .seconds(500))
        let renewed = slot.step(ready: false, windowOpen: true, now: start + PendingOpenPatience.limit + .seconds(1))
        #expect(renewed == nil)
    }
}
