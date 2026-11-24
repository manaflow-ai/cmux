import CmuxNextCompat
import Darwin
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// A handoff's stop of a daemon whose `_acpmux/shutdown` misses its deadline (Leo's restart,
/// 2026-11-12 08:05Z: the ask missed its 2 s deadline and the old build's daemon ran on for over a
/// minute) is finished by SIGTERM, acpmux's own restart handoff, never left to run on. Any other
/// failure (another home, a refusal) sends nothing.
struct AcpmuxHandOffShutdownTests {
    private nonisolated final class Signals: Sendable {
        let pids = Mutex<[Int32]>([])
    }

    private static let environment = AcpmuxEnvironment(
        executable: URL(fileURLWithPath: "/usr/bin/false"), home: URL(fileURLWithPath: "/tmp/acpmux-handoff-stop", isDirectory: true),
        socketPath: "/tmp/acpmux-handoff-stop/acpmux.sock", daemonArguments: [], childEnvironment: [:])

    @Test func aShutdownAskThatMissesItsDeadlineIsFinishedBySigterm() async throws {
        let signals = Signals()
        try await AcpmuxVersionHandoff.handOffShutdown(
            Self.environment, pid: 4242, reason: "test",
            shutdown: { _, _, _ in throw AgentPaneDeadlineExceeded(label: "acpmux _acpmux/shutdown") },
            finish: { _, pid in signals.pids.withLock { $0.append(pid) }; return true })
        #expect(signals.pids.withLock { $0 } == [4242])
    }

    @Test func aDaemonTheSignalCannotReachKeepsTheMissedDeadline() async {
        await #expect(throws: AgentPaneDeadlineExceeded(label: "acpmux _acpmux/shutdown")) {
            try await AcpmuxVersionHandoff.handOffShutdown(
                Self.environment, pid: 4242, reason: "test",
                shutdown: { _, _, _ in throw AgentPaneDeadlineExceeded(label: "acpmux _acpmux/shutdown") },
                finish: { _, _ in false })
        }
    }

    @Test func anAnsweredAskOrAnotherFailureSendsNoSignal() async {
        let signals = Signals()
        let finish: @Sendable (AcpmuxEnvironment, Int32) async -> Bool = { _, pid in signals.pids.withLock { $0.append(pid) }; return true }
        await #expect(throws: AcpmuxStatusClient.Failure.otherHome("/elsewhere")) {
            try await AcpmuxVersionHandoff.handOffShutdown(
                Self.environment, pid: 4242, reason: "test", shutdown: { _, _, _ in throw AcpmuxStatusClient.Failure.otherHome("/elsewhere") }, finish: finish)
        }
        try? await AcpmuxVersionHandoff.handOffShutdown(Self.environment, pid: 4242, reason: "test", shutdown: { _, _, _ in }, finish: finish)
        #expect(signals.pids.withLock { $0 }.isEmpty)
    }

    /// The real fallback signals only this home's own daemon: no `daemon.pid` here, so nothing.
    @Test func noDaemonOfTheHomeGetsNoSignal() async {
        #expect(await AcpmuxDaemonStop().finishHandOff(Self.environment, pid: getpid()) == false)
    }
}
