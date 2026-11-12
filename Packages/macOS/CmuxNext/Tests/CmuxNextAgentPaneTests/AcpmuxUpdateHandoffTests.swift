import CmuxNextCompat
import Darwin
@testable import CmuxNextAgentPane
import Foundation
import Testing

/// Restart to Update stops the app's acpmux daemon during the update's quit, so the new build
/// starts its own and adopts the agents, rather than meeting the old build's daemon after the
/// relaunch (2026-11-10: it kept running the old build when the one-shot handoff timed out).
/// Never a daemon that would lose its chats, nor another app's.
struct AcpmuxUpdateHandoffTests {
    @Test func aDaemonThatKeepsItsChatsIsHandedToTheNewBuild() {
        #expect(AcpmuxUpdateHandoff.decide(AcpmuxStatus(pid: 42, agentHosts: true), attached: false) == .restart)
        #expect(AcpmuxUpdateHandoff.decide(AcpmuxStatus(pid: 42, chatsOnDisk: true), attached: false) == .restart)
    }

    @Test func aDaemonThatWouldLoseItsChatsKeepsRunning() {
        guard case .keep = AcpmuxUpdateHandoff.decide(AcpmuxStatus(pid: 42), attached: false) else {
            Issue.record("a memory store without agent hosts was stopped")
            return
        }
    }

    @Test func anAttachedOrUnknownDaemonKeepsRunning() {
        guard case .keep = AcpmuxUpdateHandoff.decide(AcpmuxStatus(pid: 42, agentHosts: true), attached: true) else {
            Issue.record("another app's daemon was stopped")
            return
        }
        guard case .keep = AcpmuxUpdateHandoff.decide(AcpmuxStatus(agentHosts: true), attached: false) else {
            Issue.record("a daemon with no pid was stopped")
            return
        }
    }

    @Test func noSocketIsNoDaemon() async {
        #expect(await AcpmuxUpdateHandoff(nil).handOff(within: .milliseconds(10)) == .noDaemon)
    }
}

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
            Self.environment, pid: 4242,
            shutdown: { _, _ in throw AgentPaneDeadlineExceeded(label: "acpmux _acpmux/shutdown") },
            finish: { _, pid in signals.pids.withLock { $0.append(pid) }; return true })
        #expect(signals.pids.withLock { $0 } == [4242])
    }

    @Test func aDaemonTheSignalCannotReachKeepsTheMissedDeadline() async {
        await #expect(throws: AgentPaneDeadlineExceeded(label: "acpmux _acpmux/shutdown")) {
            try await AcpmuxVersionHandoff.handOffShutdown(
                Self.environment, pid: 4242,
                shutdown: { _, _ in throw AgentPaneDeadlineExceeded(label: "acpmux _acpmux/shutdown") },
                finish: { _, _ in false })
        }
    }

    @Test func anAnsweredAskOrAnotherFailureSendsNoSignal() async {
        let signals = Signals()
        let finish: @Sendable (AcpmuxEnvironment, Int32) async -> Bool = { _, pid in signals.pids.withLock { $0.append(pid) }; return true }
        await #expect(throws: AcpmuxStatusClient.Failure.otherHome("/elsewhere")) {
            try await AcpmuxVersionHandoff.handOffShutdown(
                Self.environment, pid: 4242, shutdown: { _, _ in throw AcpmuxStatusClient.Failure.otherHome("/elsewhere") }, finish: finish)
        }
        try? await AcpmuxVersionHandoff.handOffShutdown(Self.environment, pid: 4242, shutdown: { _, _ in }, finish: finish)
        #expect(signals.pids.withLock { $0 }.isEmpty)
    }

    /// The real fallback signals only this home's own daemon: no `daemon.pid` here, so nothing.
    @Test func noDaemonOfTheHomeGetsNoSignal() async {
        #expect(await AcpmuxDaemonStop().finishHandOff(Self.environment, pid: getpid()) == false)
    }
}
