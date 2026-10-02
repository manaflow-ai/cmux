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
}
