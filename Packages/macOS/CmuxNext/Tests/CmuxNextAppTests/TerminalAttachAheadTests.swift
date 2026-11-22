import CmuxNextBridge
import Testing

/// startup-tti: a visible pane waiting for its surface starts its terminal's attach ahead (``TerminalAttachAhead``);
/// the surface takes that one attachment, and every attachment no surface takes is closed.
@MainActor @Suite struct TerminalAttachAheadTests {
    private final class FakeIO {
        let name: String
        init(_ name: String) { self.name = name }
    }

    private final class Closed {
        var names: [String] = []
    }

    @Test func theSurfaceTakesTheAttachmentStartedAheadOnce() {
        let closed = Closed()
        let ahead = TerminalAttachAhead<FakeIO> { closed.names.append($0.name) }
        var made = 0
        #expect(ahead.start("t1", validity: "g1") { made += 1; return FakeIO("a") })
        // A second wait of the same pane makes no second attachment.
        #expect(!ahead.start("t1", validity: "g1") { made += 1; return FakeIO("b") })
        #expect(made == 1)
        #expect(ahead.take("t1", validity: "g1")?.name == "a")
        #expect(ahead.take("t1", validity: "g1") == nil)
        #expect(closed.names.isEmpty)
    }

    @Test func aStaleAttachmentIsClosedNotHandedOver() {
        let closed = Closed()
        let ahead = TerminalAttachAhead<FakeIO> { closed.names.append($0.name) }
        ahead.start("t1", validity: "g1") { FakeIO("old") }
        #expect(ahead.take("t1", validity: "g2") == nil)
        #expect(closed.names == ["old"])
        // A restart's new validity replaces the held one.
        ahead.start("t2", validity: "g1") { FakeIO("first") }
        ahead.start("t2", validity: "g2") { FakeIO("second") }
        #expect(closed.names == ["old", "first"])
        #expect(ahead.take("t2", validity: "g2")?.name == "second")
    }

    @Test func aTabThatGoesClosesItsAttachmentAndTheHoldIsBounded() {
        let closed = Closed()
        let ahead = TerminalAttachAhead<FakeIO> { closed.names.append($0.name) }
        ahead.start("gone", validity: "g") { FakeIO("gone") }
        ahead.drop("gone")
        ahead.drop("never")
        #expect(closed.names == ["gone"])
        let limit = TerminalAttachAhead<FakeIO>.limit
        for index in 0...limit { ahead.start("t\(index)", validity: "g") { FakeIO("t\(index)") } }
        #expect(ahead.keys.count == limit)
        #expect(closed.names == ["gone", "t0"])
    }
}
