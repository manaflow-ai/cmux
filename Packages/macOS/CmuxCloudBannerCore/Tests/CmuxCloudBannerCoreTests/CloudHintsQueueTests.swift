import Foundation
import Testing

@testable import CmuxCloudBannerCore

@Suite("Cloud hints queue")
@MainActor
struct CloudHintsQueueTests {
    private final class Defaults {
        let name = "cloud-hints-\(UUID().uuidString)"
        lazy var store: UserDefaults = UserDefaults(suiteName: name)!
        deinit { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    }

    private func makeQueue(_ defaults: Defaults) -> CloudHintsQueue {
        CloudHintsQueue(dismissals: CloudBannerDismissalStore(defaults: defaults.store))
    }

    @Test("shows at most one tip, highest priority first, offer order among equals")
    func showsOneTipByPriority() {
        let defaults = Defaults()
        let queue = makeQueue(defaults)
        queue.offer(CloudHint(id: "a", priority: 1))
        queue.offer(CloudHint(id: "b", priority: 1))
        queue.offer(CloudHint(id: "c", priority: 5))
        #expect(queue.current(isBlocked: false)?.id == "c")
        queue.retire("c")
        #expect(queue.current(isBlocked: false)?.id == "a")
        queue.retire("a")
        #expect(queue.current(isBlocked: false)?.id == "b")
    }

    @Test("a busy panel shows no tip but keeps the queue")
    func blockedPanelShowsNothing() {
        let defaults = Defaults()
        let queue = makeQueue(defaults)
        queue.offer(CloudHint(id: "a"))
        #expect(queue.current(isBlocked: true) == nil)
        #expect(queue.current(isBlocked: false)?.id == "a")
    }

    @Test("a retired tip stays retired across stores on the same defaults")
    func retirementPersists() {
        let defaults = Defaults()
        let first = makeQueue(defaults)
        first.offer(CloudHint(id: "a"))
        first.retire("a")
        #expect(first.current(isBlocked: false) == nil)

        let second = makeQueue(defaults)
        #expect(second.isRetired("a"))
        #expect(second.offer(CloudHint(id: "a")) == false)
        #expect(second.current(isBlocked: false) == nil)
    }

    @Test("retiring before the tip is offered prevents it: doing the thing teaches it")
    func retireBeforeOffer() {
        let defaults = Defaults()
        let queue = makeQueue(defaults)
        queue.retire("shortcut")
        #expect(queue.offer(CloudHint(id: "shortcut")) == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("a tip that stayed on screen retires when it leaves, and only that one")
    func seenTipRetires() {
        let defaults = Defaults()
        let queue = makeQueue(defaults)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        queue.offer(CloudHint(id: "a", priority: 2))
        queue.offer(CloudHint(id: "b", priority: 1))
        queue.noteDisplayed(queue.current(isBlocked: false)?.id, at: start)
        queue.noteDisplayEnded(at: start.addingTimeInterval(CloudHintsQueue.minimumSeenDuration))
        #expect(queue.isRetired("a"))
        #expect(!queue.isRetired("b"))
        #expect(queue.current(isBlocked: false)?.id == "b")
    }

    @Test("a glance shorter than the seen duration keeps the tip")
    func glanceKeepsTip() {
        let defaults = Defaults()
        let queue = makeQueue(defaults)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        queue.offer(CloudHint(id: "a"))
        queue.noteDisplayed("a", at: start)
        queue.noteDisplayEnded(at: start.addingTimeInterval(CloudHintsQueue.minimumSeenDuration / 2))
        #expect(!queue.isRetired("a"))
        #expect(queue.current(isBlocked: false)?.id == "a")
    }

    @Test("redrawing keeps the first appearance; drawing nothing ends the display")
    func redrawKeepsStart() {
        let defaults = Defaults()
        let queue = makeQueue(defaults)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        queue.offer(CloudHint(id: "a"))
        queue.noteDisplayed("a", at: start)
        queue.noteDisplayed("a", at: start.addingTimeInterval(10))
        #expect(queue.displayed?.since == start)
        queue.noteDisplayed(nil, at: start.addingTimeInterval(11))
        #expect(queue.displayed == nil)
        #expect(queue.isRetired("a"))
    }

    @Test("withdrawing drops a pending tip without retiring it")
    func withdrawKeepsTipEarnable() {
        let defaults = Defaults()
        let queue = makeQueue(defaults)
        queue.offer(CloudHint(id: "key"))
        queue.withdraw("key")
        #expect(queue.current(isBlocked: false) == nil)
        #expect(!queue.isRetired("key"))
        #expect(queue.offer(CloudHint(id: "key")))
    }

    @Test("re-offering a pending tip refreshes its subject without duplicating it")
    func reofferRefreshesSubject() {
        let defaults = Defaults()
        let queue = makeQueue(defaults)
        queue.offer(CloudHint(id: "machine", subject: "brave-otter"))
        queue.offer(CloudHint(id: "machine", subject: "calm-heron"))
        #expect(queue.pending.count == 1)
        #expect(queue.current(isBlocked: false)?.subject == "calm-heron")
    }

    @Test("tip retirement shares the banner store without touching banner entries")
    func sharesBannerStore() {
        let defaults = Defaults()
        let dismissals = CloudBannerDismissalStore(defaults: defaults.store)
        dismissals.dismiss(id: "machines.stale", signature: "boom")
        let queue = CloudHintsQueue(dismissals: dismissals)
        queue.retire("a")
        #expect(dismissals.isDismissed(id: "machines.stale", signature: "boom"))
        #expect(dismissals.isDismissed(id: CloudHintsQueue.dismissalID(for: "a"), signature: CloudHintsQueue.retirementSignature))
    }
}
