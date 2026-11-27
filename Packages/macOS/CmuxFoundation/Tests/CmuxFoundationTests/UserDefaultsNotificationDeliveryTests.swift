import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Preference notification delivery")
struct UserDefaultsNotificationDeliveryTests {
    @Test @MainActor func mainThreadPostsDeliverSynchronously() {
        let center = NotificationCenter()
        var deliveries = 0
        let observer = center.addUserDefaultsObserver { deliveries += 1 }
        defer { center.removeObserver(observer) }

        center.post(name: UserDefaults.didChangeNotification, object: nil)

        #expect(deliveries == 1)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func backgroundWriterReturnsWhileMainThreadIsOccupied() async {
        let center = NotificationCenter()
        let (deliveries, continuation) = AsyncStream<Void>.makeStream()
        let observer = center.addUserDefaultsObserver {
            MainActor.preconditionIsolated()
            continuation.yield()
        }
        defer {
            center.removeObserver(observer)
            continuation.finish()
        }
        let posted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            center.post(name: UserDefaults.didChangeNotification, object: nil)
            posted.signal()
        }
        // Hold main until the writer returns, with a finite failure deadline.
        // A synchronous main-queue observer cannot complete this sequence.
        #expect(Self.waitForPostWhileMainThreadIsOccupied(posted))
        var iterator = deliveries.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @MainActor private static func waitForPostWhileMainThreadIsOccupied(_ posted: DispatchSemaphore) -> Bool {
        posted.wait(timeout: .now() + 1) == .success
    }

    @Test @MainActor func objectFilteringAndRemovalRemainEffective() {
        let center = NotificationCenter()
        let expected = NSObject()
        let other = NSObject()
        var deliveries = 0
        let observer = center.addUserDefaultsObserver(object: expected) { deliveries += 1 }
        center.post(name: UserDefaults.didChangeNotification, object: other)
        #expect(deliveries == 0)
        center.post(name: UserDefaults.didChangeNotification, object: expected)
        #expect(deliveries == 1)

        center.removeObserver(observer)
        center.post(name: UserDefaults.didChangeNotification, object: expected)
        #expect(deliveries == 1)
    }
}
