import CmuxNextCompat
import Foundation
import Testing

@MainActor
@Suite struct MainActorObservationTests {
    private let name = Notification.Name("MainActorObservationTests.ping")

    @Test func runsTheHandlerForEachPostFromItsObject() {
        let center = NotificationCenter()
        let sender = NSObject(), other = NSObject()
        var runs = 0
        let token = MainActorObservation(name, object: sender, center: center) { runs += 1 }
        center.post(name: name, object: sender)
        center.post(name: name, object: other)
        center.post(name: name, object: sender)
        #expect(runs == 2)
        withExtendedLifetime(token) {}
    }

    @Test func releasingOrCancellingTheTokenStopsDelivery() {
        let center = NotificationCenter()
        var runs = 0
        var token: MainActorObservation? = MainActorObservation(name, center: center) { runs += 1 }
        center.post(name: name, object: nil)
        token = nil
        center.post(name: name, object: nil)
        #expect(runs == 1)
        let second = MainActorObservation(name, center: center) { runs += 1 }
        second.cancel()
        center.post(name: name, object: nil)
        #expect(runs == 1)
        #expect(token == nil)
    }
}
