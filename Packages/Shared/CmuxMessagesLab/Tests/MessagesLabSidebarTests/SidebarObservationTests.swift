import Foundation
import Testing
@testable import MessagesLabSidebar

/// SWIFT 6: the controller's scroll and key-window observers and the root
/// view's window observers are ``SidebarObservation`` tokens, removed when their owner releases
/// them (no main-actor `deinit` reads them). Each test has its own NotificationCenter.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SidebarObservationTests {
    private static let name = Notification.Name("SidebarObservationTests.changed")

    /// A post on the main thread reaches the handler once.
    @Test func postDeliversOnce() async {
        let center = NotificationCenter()
        let log = DeliveryLog()
        let observation = SidebarObservation(Self.name, center: center) { log.record() }
        center.post(name: Self.name, object: nil)
        await Self.mainQueueDrained()
        #expect(log.count == 1)
        withExtendedLifetime(observation) {}
    }

    /// A post from a background thread reaches the handler on the main thread.
    @Test func backgroundPostDeliversOnMain() async {
        let center = NotificationCenter()
        let log = DeliveryLog()
        let observation = SidebarObservation(Self.name, center: center) { log.record() }
        await Self.postOffMain(center, Self.name)
        await Self.mainQueueDrained()
        #expect(log.count == 1)
        #expect(log.allOnMain)
        withExtendedLifetime(observation) {}
    }

    /// Releasing the token stops delivery (it removes its observer from the center).
    @Test func releasedTokenStopsDelivery() async {
        let center = NotificationCenter()
        let log = DeliveryLog()
        var observation: SidebarObservation? = SidebarObservation(Self.name, center: center) { log.record() }
        center.post(name: Self.name, object: nil)
        await Self.mainQueueDrained()
        #expect(log.count == 1)
        weak var released = observation
        observation = nil
        #expect(released == nil)
        center.post(name: Self.name, object: nil)
        await Self.postOffMain(center, Self.name)
        await Self.mainQueueDrained()
        #expect(log.count == 1)
    }

    /// Posts `name` from a global-queue thread; returns once the post call returned there.
    nonisolated private static func postOffMain(_ center: NotificationCenter, _ name: Notification.Name) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                center.post(name: name, object: nil)
                done.resume()
            }
        }
    }

    /// Returns after every block the main queue held at the call has run (it is serial, first in first out).
    nonisolated private static func mainQueueDrained() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            OperationQueue.main.addOperation { done.resume() }
        }
    }
}

/// What a test's handler saw: how many deliveries, and whether each was on the main thread.
@MainActor
private final class DeliveryLog {
    private(set) var count = 0
    private(set) var allOnMain = true

    func record() {
        count += 1
        allOnMain = allOnMain && Thread.isMainThread
    }
}
