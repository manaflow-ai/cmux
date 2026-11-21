import CmuxNextPages
import Testing

/// An overlay panel whose page the open itself made (the icon picker with no earlier sign of intent) stays off screen
/// until its page has drawn, then shows in one step; it showed as a blank card that filled in about 0.7 s later.
@MainActor
struct PageRevealGateTests {
    @Test func aReadyPageShowsAtOnce() {
        let gate = PageRevealGate(owner: "PageRevealGateTests")
        var shown = 0
        gate.hold(ready: true, limit: .seconds(5)) { shown += 1 }
        #expect(shown == 1)
        #expect(!gate.isHolding)
    }

    @Test func aPageNotReadyShowsWhenItIsAndOnlyOnce() {
        let gate = PageRevealGate(owner: "PageRevealGateTests")
        var shown = 0
        gate.hold(ready: false, limit: .seconds(5)) { shown += 1 }
        #expect(shown == 0, "the panel showed before its page drew")
        gate.open()
        #expect(shown == 1)
        gate.open()
        #expect(shown == 1, "a later ready showed the panel again")
    }

    @Test func aPageThatNeverGetsReadyShowsAtTheLimit() async throws {
        let gate = PageRevealGate(owner: "PageRevealGateTests")
        var shown = 0
        gate.hold(ready: false, limit: .milliseconds(20)) { shown += 1 }
        for _ in 0..<100 where shown == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(shown == 1, "a page that never drew kept the panel off screen")
    }

    @Test func aCancelledOrReplacedOpenNeverShows() {
        let gate = PageRevealGate(owner: "PageRevealGateTests")
        var first = 0, second = 0
        gate.hold(ready: false, limit: .seconds(5)) { first += 1 }
        gate.hold(ready: false, limit: .seconds(5)) { second += 1 }
        gate.open()
        #expect(first == 0, "a replaced open showed")
        #expect(second == 1)
        gate.hold(ready: false, limit: .seconds(5)) { first += 1 }
        gate.cancel()
        gate.open()
        #expect(first == 0, "a cancelled open showed")
    }
}
