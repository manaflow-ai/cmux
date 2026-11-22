import CmuxNextDesign
import CmuxNextTerminal
import Testing
@testable import CmuxNextApp

/// Deferrable launch work (the palette warm-up) waits for the first live
/// terminal frame instead of running between the first window and it.
@MainActor
@Suite struct LaunchSettleTests {
    @Test func workWaitsForTheSettleAndRunsOnce() {
        let settle = LaunchSettle()
        var runs: [String] = []
        settle.whenSettled { runs.append("palette") }
        #expect(runs.isEmpty)
        settle.settle()
        settle.settle()
        #expect(runs == ["palette"])
        settle.whenSettled { runs.append("late") }
        #expect(runs == ["palette", "late"])
    }

    @Test func anUnavailableDaemonSettles() async {
        let daemon = DaemonService()
        daemon.startupDeadline = .zero
        let settle = LaunchSettle()
        settle.install(daemon: daemon)
        defer { TerminalTimings.onContentApplied = nil }
        await withCheckedContinuation { continuation in
            settle.whenSettled { continuation.resume() }
            daemon.noteStartupFailure(.binaryNotFound(searched: []))
        }
        #expect(settle.isSettled)
    }

    /// A launch whose first pane is a page or an agent (no terminal) settles
    /// when that content shows: deferred work (the download temp-file
    /// cleanup, the palette warm-up) must not wait for a terminal frame that
    /// never comes.
    @Test func aFirstPaneThatIsNotATerminalSettles() {
        let reveal = LaunchReveal()
        let settle = LaunchSettle(reveal: reveal)
        settle.install(daemon: DaemonService())
        defer { TerminalTimings.onContentApplied = nil }
        var runs = 0
        settle.whenSettled { runs += 1 }
        reveal.markReady(.pane)
        #expect(settle.isSettled)
        #expect(runs == 1)
    }
}
