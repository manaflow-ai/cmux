import Testing

@testable import CmuxMobileTerminal

@Suite("Effective grid scroll gate")
struct TerminalEffectiveGridScrollGateTests {
    @Test("an undocked scroll anchor holds the newest grid update")
    func undockedAnchorHoldsLatestUpdate() {
        var gate = TerminalEffectiveGridScrollGate()

        #expect(gate.submit(.remoteGrid(columns: 75, rows: 61), anchorUndocked: true) == nil)
        #expect(gate.submit(.remoteGrid(columns: 103, rows: 45), anchorUndocked: true) == nil)
        #expect(gate.pending == .remoteGrid(columns: 103, rows: 45))
        #expect(gate.flushIfSafe(anchorUndocked: true) == nil)
        #expect(gate.pending == .remoteGrid(columns: 103, rows: 45))
    }

    @Test("the held update is released after the anchor reaches the tail")
    func releasesAtTail() {
        var gate = TerminalEffectiveGridScrollGate()
        #expect(gate.submit(.remoteGrid(columns: 75, rows: 61), anchorUndocked: true) == nil)

        #expect(gate.flushIfSafe(anchorUndocked: false) == .remoteGrid(columns: 75, rows: 61))
        #expect(gate.pending == nil)
    }

    @Test("safe submissions replace stale pending work")
    func safeSubmissionWins() {
        var gate = TerminalEffectiveGridScrollGate()
        #expect(gate.submit(.remoteGrid(columns: 75, rows: 61), anchorUndocked: true) == nil)

        #expect(gate.submit(.natural, anchorUndocked: false) == .natural)
        #expect(gate.pending == nil)
    }
}
