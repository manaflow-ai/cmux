import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct PendingNotificationDismissQueueTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "dismiss-queue-\(UUID().uuidString)")!
    }

    @Test func enqueueTrimsAndDropsBlankIDs() {
        let queue = PendingNotificationDismissQueue(defaults: makeDefaults())

        queue.enqueue(["  n-1  ", "", "   ", "n-2"])

        #expect(queue.pendingIDs == ["n-1", "n-2"])
    }

    @Test func enqueueKeepsDuplicatesOnceAndPreservesOrder() {
        let queue = PendingNotificationDismissQueue(defaults: makeDefaults())

        queue.enqueue(["a", "b"])
        queue.enqueue(["b", "c", "a"])

        #expect(queue.pendingIDs == ["a", "b", "c"])
    }

    @Test func removeDropsOnlyConfirmedIDs() {
        let queue = PendingNotificationDismissQueue(defaults: makeDefaults())
        queue.enqueue(["a", "b", "c"])

        queue.remove(["b", "missing"])

        #expect(queue.pendingIDs == ["a", "c"])
    }

    @Test func removingEverythingClearsTheBackingKey() {
        let defaults = makeDefaults()
        let queue = PendingNotificationDismissQueue(defaults: defaults)
        queue.enqueue(["a"])

        queue.remove(["a"])

        #expect(queue.pendingIDs.isEmpty)
        #expect(defaults.object(forKey: "cmux.notifications.pendingMacDismissIds") == nil)
    }

    @Test func capacityEvictsOldestFirst() {
        let queue = PendingNotificationDismissQueue(defaults: makeDefaults())

        queue.enqueue((0..<130).map { "n-\($0)" })

        let pending = queue.pendingIDs
        #expect(pending.count == 128)
        #expect(pending.first == "n-2")
        #expect(pending.last == "n-129")
    }

    @Test func separateInstancesStayCoherentOverSharedDefaults() {
        let defaults = makeDefaults()
        let coordinatorSide = PendingNotificationDismissQueue(defaults: defaults)
        let compositeSide = PendingNotificationDismissQueue(defaults: defaults)

        coordinatorSide.enqueue(["n-1"])
        #expect(compositeSide.pendingIDs == ["n-1"])

        compositeSide.remove(["n-1"])
        #expect(coordinatorSide.pendingIDs.isEmpty)
    }
}
