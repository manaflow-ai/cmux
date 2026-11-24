import Testing
@testable import CmuxMobileLive

/// Finding on #50262 (Greptile): a Stop that waited for the link must not stop the next turn.
@Suite struct StopTiedToTurnTests {
    @Test func aDelayedStopOnlyAppliesToTheTurnItWasPressedFor() {
        #expect(AcpmuxSessionSource.stopStillApplies(pressedFor: "t1", running: "t1"))
        #expect(!AcpmuxSessionSource.stopStillApplies(pressedFor: "t1", running: "t2"), "the next turn is not stopped")
        #expect(!AcpmuxSessionSource.stopStillApplies(pressedFor: "t1", running: nil), "that work already ended")
        #expect(AcpmuxSessionSource.stopStillApplies(pressedFor: nil, running: "t2"), "unknown at the press: as before")
    }
}
