import Foundation
import Testing
@testable import CmuxMobileToast

@MainActor
struct ToastCenterTests {
    private func makeCenter() -> (ToastCenter, ManualClock) {
        let clock = ManualClock()
        let center = ToastCenter(
            clock: clock,
            defaults: UserDefaults(suiteName: "toast-tests-\(UUID().uuidString)")!
        )
        center.isEnabled = true
        center.prefersExtendedDwell = { false }
        return (center, clock)
    }

    @Test func disabledCenterDropsEveryPresent() {
        let clock = ManualClock()
        let center = ToastCenter(
            clock: clock,
            defaults: UserDefaults(suiteName: "toast-tests-\(UUID().uuidString)")!
        )
        // Off by default (beta flag).
        #expect(center.isEnabled == false)
        center.present(.success("dropped"))
        #expect(center.presented == nil)
        #expect(center.queue.isEmpty)

        center.isEnabled = true
        center.present(.success("shown"))
        #expect(center.presented?.toast.message == "shown")

        // Turning the flag off clears anything on screen.
        center.isEnabled = false
        #expect(center.presented == nil)
    }

    /// Yields until `condition` holds, so a task spawned by the center can
    /// reach its clock.sleep suspension before the test advances the clock.
    private func yieldUntil(
        _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never became true", sourceLocation: sourceLocation)
    }

    @Test func presentShowsImmediately() {
        let (center, _) = makeCenter()
        center.present(.success("done"))
        #expect(center.presented?.toast.message == "done")
        #expect(center.presented?.bumpCount == 0)
    }

    @Test func autoDismissFiresAfterStyleDwell() async {
        let (center, clock) = makeCenter()
        center.present(.success("done"))
        await yieldUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(3.4))
        // Not yet: success dwell is 3.5s.
        #expect(center.presented != nil)
        clock.advance(by: .seconds(0.2))
        await center.autoDismissTask?.value
        #expect(center.presented == nil)
    }

    @Test func failureDwellsLongerThanSuccess() async {
        let (center, clock) = makeCenter()
        center.present(.failure("broke"))
        await yieldUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(4))
        #expect(center.presented != nil)
        clock.advance(by: .seconds(2.1))
        await center.autoDismissTask?.value
        #expect(center.presented == nil)
    }

    @Test func persistentToastNeverAutoDismisses() async {
        let (center, clock) = makeCenter()
        center.present(.warning("reconnecting", autoDismiss: .never))
        #expect(center.autoDismissTask == nil)
        clock.advance(by: .seconds(60))
        #expect(center.presented != nil)
        center.dismissCurrent()
        #expect(center.presented == nil)
    }

    @Test func presentWhileShowingQueuesFIFO() async {
        let (center, clock) = makeCenter()
        center.present(.success("first"))
        center.present(.info("second"))
        center.present(.warning("third"))
        #expect(center.presented?.toast.message == "first")
        #expect(center.queue.map(\.message) == ["second", "third"])

        center.dismissCurrent()
        #expect(center.presented == nil)
        await yieldUntil { clock.sleeperCount == 1 }
        clock.advance(by: ToastCenter.interToastGap)
        await center.advanceTask?.value
        #expect(center.presented?.toast.message == "second")
        #expect(center.queue.map(\.message) == ["third"])
    }

    @Test func queueCapDropsOldestQueued() {
        let (center, _) = makeCenter()
        center.present(.info("visible"))
        for index in 1...5 {
            center.present(.info("queued \(index)"))
        }
        #expect(center.queue.count == ToastCenter.queueLimit)
        #expect(center.queue.map(\.message) == ["queued 3", "queued 4", "queued 5"])
    }

    @Test func coalescingBumpsInsteadOfQueueing() async {
        let (center, clock) = makeCenter()
        center.present(.failure("offline", coalescingKey: "net"))
        let firstID = center.presented?.toast.id
        await yieldUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(4))

        center.present(.failure("still offline", coalescingKey: "net"))
        // Same identity (no re-entrance animation), refreshed content, bumped.
        #expect(center.presented?.toast.id == firstID)
        #expect(center.presented?.toast.message == "still offline")
        #expect(center.presented?.bumpCount == 1)
        #expect(center.queue.isEmpty)

        // The bump restarted the full dwell: the original deadline passing
        // must not dismiss it.
        await yieldUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(4))
        #expect(center.presented != nil)
        clock.advance(by: .seconds(2.1))
        await center.autoDismissTask?.value
        #expect(center.presented == nil)
    }

    @Test func coalescingAgainstQueuedToastReplacesInPlace() {
        let (center, _) = makeCenter()
        center.present(.info("visible"))
        center.present(.failure("offline", coalescingKey: "net"))
        center.present(.failure("still offline", coalescingKey: "net"))
        #expect(center.queue.count == 1)
        #expect(center.queue.first?.message == "still offline")
    }

    @Test func interactionHoldPausesAutoDismiss() async {
        let (center, clock) = makeCenter()
        let toast = Toast.success("done")
        center.present(toast)
        await yieldUntil { clock.sleeperCount == 1 }

        center.beginInteraction(for: toast.id)
        #expect(center.autoDismissTask == nil)
        clock.advance(by: .seconds(30))
        #expect(center.presented != nil)

        center.endInteraction(for: toast.id)
        await yieldUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(3.6))
        await center.autoDismissTask?.value
        #expect(center.presented == nil)
    }

    @Test func staleInteractionFromDepartedToastIsIgnored() async {
        let (center, clock) = makeCenter()
        let first = Toast.success("first")
        center.present(first)
        center.dismissCurrent()
        let second = Toast.success("second")
        center.present(second)
        await yieldUntil { clock.sleeperCount == 1 }

        // A straggling gesture from the departed toast must not pause or
        // resume the visible toast's dwell.
        center.beginInteraction(for: first.id)
        #expect(center.autoDismissTask != nil)
        center.endInteraction(for: first.id)
        clock.advance(by: .seconds(3.6))
        await center.autoDismissTask?.value
        #expect(center.presented == nil)
    }

    @Test func extendedDwellDoublesDuration() async {
        let (center, clock) = makeCenter()
        center.prefersExtendedDwell = { true }
        center.present(.success("done"))
        await yieldUntil { clock.sleeperCount == 1 }
        clock.advance(by: .seconds(4))
        #expect(center.presented != nil)
        clock.advance(by: .seconds(3.1))
        await center.autoDismissTask?.value
        #expect(center.presented == nil)
    }

    @Test func presentDuringAdvanceGapPreservesFIFO() async {
        let (center, clock) = makeCenter()
        center.present(.info("first"))
        center.present(.info("second"))
        center.dismissCurrent()
        // During the inter-toast gap a new present must not jump the queue.
        center.present(.info("third"))
        await yieldUntil { clock.sleeperCount == 1 }
        clock.advance(by: ToastCenter.interToastGap)
        await center.advanceTask?.value
        #expect(center.presented?.toast.message == "second")
        #expect(center.queue.map(\.message) == ["third"])
    }

    @Test func dismissByIDRemovesQueuedToast() {
        let (center, _) = makeCenter()
        center.present(.info("visible"))
        let queued = Toast.info("queued")
        center.present(queued)
        center.dismiss(queued.id)
        #expect(center.queue.isEmpty)
        #expect(center.presented?.toast.message == "visible")
    }

    @Test func dismissAllClearsEverything() {
        let (center, _) = makeCenter()
        center.present(.info("visible"))
        center.present(.info("queued"))
        center.dismissAll()
        #expect(center.presented == nil)
        #expect(center.queue.isEmpty)
        #expect(center.autoDismissTask == nil)
        #expect(center.advanceTask == nil)
    }

    @Test func actionBearingToastGetsLongerDefaultDwell() {
        let toast = Toast.success("done", action: Toast.Action(label: "Undo") {})
        #expect(toast.autoDismiss == .after(.seconds(6)))
    }

    @Test func defaultCoalescingKeyMatchesIdenticalContent() {
        let first = Toast.failure("offline", title: "Sync failed")
        let second = Toast.failure("offline", title: "Sync failed")
        #expect(first.coalescingKey == second.coalescingKey)
        #expect(first.id != second.id)
    }
}
