import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// A hidden terminal that let its surface go (p01-process-140) rebuilds it from a fresh attach, not a
/// `snapshot-request`: a byte-mode attach has no snapshot to ask for, the daemon throttles requests, and an
/// exited terminal has no live link to ask on. A refresh re-attaches in every phase and its replay brings
/// the whole screen; a refused attach retries as any re-attach.
struct TerminalAttachRefreshTests {
    typealias Machine = TerminalAttachMachine<Int>

    private func opened(_ effects: [Machine.Effect]) -> Int? {
        for effect in effects {
            switch effect {
            case .open(let attempt, _), .openAfterBackoff(let attempt, _, _): return attempt
            default: continue
            }
        }
        return nil
    }

    private func live(visible: Bool = true) throws -> Machine {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: visible)
        let attempt = try #require(opened(machine.reduce(.start)))
        _ = machine.reduce(.opened(1, attempt: attempt))
        _ = machine.reduce(.replayDelivered(1))
        try #require(machine.liveLink == 1)
        return machine
    }

    @Test func aRefreshOfALiveViewReattachesForAFreshReplayWithNoStatusChange() throws {
        var machine = try live()
        let effects = machine.reduce(.refresh)
        #expect(effects.first == .detach(1), "the old link stayed open")
        let attempt = try #require(opened(effects), "a refresh did not re-attach")
        #expect(!effects.contains { if case .status = $0 { true } else { false } }, "a refresh showed a status")
        #expect(machine.status == .connected)

        _ = machine.reduce(.opened(2, attempt: attempt))
        _ = machine.reduce(.replayDelivered(2))
        #expect(machine.liveLink == 2)
        #expect(machine.status == .connected)
    }

    @Test func aRefusedRefreshRetriesByItself() throws {
        var machine = try live()
        var attempt = try #require(opened(machine.reduce(.refresh)))
        for _ in 1...3 {
            attempt = try #require(opened(machine.reduce(.openFailed(attempt: attempt))), "a refused refresh gave up")
        }
        _ = machine.reduce(.opened(9, attempt: attempt))
        _ = machine.reduce(.replayDelivered(9))
        #expect(machine.liveLink == 9)
    }

    @Test func anExitedTerminalAttachesOnceForItsFinalScreen() throws {
        var machine = try live(visible: false)
        _ = machine.reduce(.processExited)
        #expect(machine.phase == .exited)

        let attempt = try #require(opened(machine.reduce(.refresh)), "an exited terminal's final screen was not asked for")
        _ = machine.reduce(.opened(2, attempt: attempt))
        let effects = machine.reduce(.replayDelivered(2))
        #expect(effects.contains(.detach(2)), "the final screen's link stayed open")
        #expect(machine.phase == .exited)
        #expect(machine.status == .exited)

        // A final attach the daemon refuses leaves it exited, with no retry.
        let refused = try #require(opened(machine.reduce(.refresh)))
        #expect(opened(machine.reduce(.openFailed(attempt: refused))) == nil)
        #expect(machine.phase == .exited)
    }

    @Test func aDisconnectedHiddenViewReattachesOnARefresh() throws {
        var machine = try live(visible: false)
        _ = machine.reduce(.ended(1, .connectionLost("gone")))
        #expect(machine.status == .disconnected(.connectionLost, reconnecting: false))
        #expect(opened(machine.reduce(.refresh)) != nil)
    }
}
