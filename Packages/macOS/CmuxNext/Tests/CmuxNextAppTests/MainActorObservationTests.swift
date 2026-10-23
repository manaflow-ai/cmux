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

@MainActor
@Suite struct MainActorObservationReadTests {
    @Test func handsTheHandlerTheValueReadFromEachNotification() {
        let center = NotificationCenter()
        let name = Notification.Name("MainActorObservationReadTests.value")
        var seen: [Int] = []
        let token = MainActorObservation(name, center: center, read: { $0.userInfo?["n"] as? Int ?? -1 }) { seen.append($0) }
        center.post(name: name, object: nil, userInfo: ["n": 3])
        center.post(name: name, object: nil)
        #expect(seen == [3, -1])
        withExtendedLifetime(token) {}
    }
}
