import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// Panes that showed "Disconnected: could not attach · Click or type to
/// reconnect" stayed that way: a visible view gave up after 8 failed
/// re-attaches (about 90 s), and nothing re-attached it while the daemon's
/// control connection stayed up (a refused attach connection, a busy daemon).
/// A visible view now keeps re-attaching at the capped backoff until one
/// attach works; after about 90 s it also offers Retry.
struct TerminalAttachRetryTests {
    typealias Machine = TerminalAttachMachine<Int>

    /// The attempt the effects open, by itself (after a backoff) or at once.
    private func opened(_ effects: [Machine.Effect]) -> Int? {
        for effect in effects {
            switch effect {
            case .open(let attempt, _), .openAfterBackoff(let attempt, _, _): return attempt
            default: continue
            }
        }
        return nil
    }

    @Test func aVisibleViewNeverStopsReattachingWhileAttachesFail() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true)
        var attempt = try #require(opened(machine.reduce(.start)))
        for failure in 1...40 {
            let effects = machine.reduce(.openFailed(attempt: attempt))
            attempt = try #require(opened(effects), "a visible view stopped re-attaching by itself")
            // Quiet while the backoff is short, then Retry shows (the view still retries).
            let offersRetry = failure > Machine.quietReconnects
            #expect(machine.status == .disconnected(.attachFailed, reconnecting: !offersRetry))
        }

        // A click or key re-attaches at once, cutting the backoff short.
        attempt = try #require(opened(machine.reduce(.focused)))
        #expect(machine.status == .disconnected(.attachFailed, reconnecting: true))

        // The daemon answers again: the next attach goes live with no input.
        _ = machine.reduce(.opened(7, attempt: attempt))
        _ = machine.reduce(.replayDelivered(7))
        #expect(machine.liveLink == 7)
        #expect(machine.status == .connected)
    }

    @Test func aHiddenViewStillWaitsToBeShown() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: false)
        let attempt = try #require(opened(machine.reduce(.start)))
        let effects = machine.reduce(.openFailed(attempt: attempt))
        #expect(opened(effects) == nil)
        #expect(machine.status == .disconnected(.attachFailed, reconnecting: false))
        // Shown again: it re-attaches at once.
        #expect(opened(machine.reduce(.visibility(true))) != nil)
    }
}
