import Testing
@testable import CmuxMobileTerminal

/// User report 2026-10-14: a reset and its replay lay out once, at the end.
@Suite struct TerminalReplayGateTests {
    @Test func aReplayFedOverSeveralFramesIsOneStep() {
        var gate = TerminalReplayGate()
        gate.received(2, isReset: true)
        #expect(gate.isReplaying)
        // The reset's own batch is parsed: still replaying.
        var done = gate.parsed(2); #expect(!done)
        gate.received(900_000, isReset: false)
        done = gate.parsed(256_000); #expect(!done)
        done = gate.parsed(256_000); #expect(!done)
        #expect(gate.isReplaying)
        done = gate.parsed(388_000); #expect(done)
        #expect(!gate.isReplaying)
        // Live output after it is not gated.
        gate.received(40, isReset: false)
        #expect(!gate.isReplaying)
        done = gate.parsed(40); #expect(!done)
    }

    @Test func theCapEndsAStuckReplay() {
        var gate = TerminalReplayGate()
        gate.received(2, isReset: true)
        gate.expire()
        #expect(!gate.isReplaying)
    }

    /// Verifier V3-2: after a drop while reading mid-stream the page froze (its
    /// document never grew again) until another drop. The gate's only deadline
    /// was the held frame's timer, which a reset during a scroll, or a second
    /// reset while a frame was held, never armed. The gate keeps its own.
    @Test func aReplayNeverFullyParsedStopsGatingAtItsOwnDeadline() {
        var gate = TerminalReplayGate()
        gate.received(2, isReset: true, at: 10)
        gate.received(50_000, isReset: false, at: 10)
        _ = gate.parsed(10_000)
        var expired = gate.expireIfOverdue(at: 10.5)
        #expect(!expired)
        #expect(gate.isReplaying)
        expired = gate.expireIfOverdue(at: 10 + TerminalReplayGate.deadline)
        #expect(expired)
        #expect(!gate.isReplaying)
    }

    @Test func aLaterResetMovesTheDeadline() {
        var gate = TerminalReplayGate()
        gate.received(2, isReset: true, at: 10)
        gate.received(2, isReset: true, at: 11)
        // The first reset's timer fires: not overdue for the second.
        var expired = gate.expireIfOverdue(at: 10 + TerminalReplayGate.deadline)
        #expect(!expired)
        #expect(gate.isReplaying)
        expired = gate.expireIfOverdue(at: 11 + TerminalReplayGate.deadline)
        #expect(expired)
    }
}
