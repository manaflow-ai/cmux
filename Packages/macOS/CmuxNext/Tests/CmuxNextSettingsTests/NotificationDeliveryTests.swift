import CmuxNextSettings
import Testing

struct NotificationDeliveryTests {
    @Test func configuredEventsLimitOnlyTheirOwnDelivery() {
        let snapshot = CmuxConfigSnapshot.parse([
            "notifications": ["delivery": ["finished": "inApp", "error": "bannerOnly"], "sounds": ["when": "always"]],
        ], validDensities: [], validMetrics: [])
        #expect(snapshot.diagnostics.isEmpty)
        let policy = NotificationPolicy(prefs: snapshot.notifications)
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.soundEvent = .finished
        let finished = policy.decide(arrival)
        #expect(!finished.alerts && !finished.desktop && finished.sound == nil && finished.bounce == nil)
        #expect(finished.attention && !finished.acknowledge)
        arrival.soundEvent = .error
        let error = policy.decide(arrival)
        #expect(error.desktop && error.sound == nil)
        arrival.workspaceMuted = true
        #expect(!policy.decide(arrival).desktop)
        arrival.workspaceMuted = false
        arrival.soundEvent = .needsInput
        let input = policy.decide(arrival)
        #expect(input.desktop && input.sound != nil)
        arrival.paneIsViewed = true
        arrival.soundEvent = .finished
        let viewed = policy.decide(arrival)
        #expect(viewed.acknowledge && viewed.sound == nil)
    }

    @Test func inputDeliveryCanKeepTheExistingHandoffSound() {
        let snapshot = CmuxConfigSnapshot.parse(["notifications": [
            "delivery": ["message": "inApp", "needsInput": "inherit"],
            "sounds": ["events": ["message": "Glass"]],
        ]], validDensities: [], validMetrics: [])
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.soundEvent = .message
        arrival.deliveryEvent = .needsInput
        let decision = NotificationPolicy(prefs: snapshot.notifications).decide(arrival)
        #expect(decision.desktop && decision.sound == "Glass")
    }

    @Test func invalidLevelKeepsTheEventDefault() {
        let snapshot = CmuxConfigSnapshot.parse(["notifications": ["delivery": ["finished": "bad", "bell": "inApp"]]],
                                                validDensities: [], validMetrics: [])
        #expect(snapshot.diagnostics.map(\.path) == ["notifications.delivery.finished"])
        #expect(snapshot.notifications.permitsBanner(for: .finished))
        #expect(!snapshot.notifications.permitsBanner(for: .bell))
    }
}
