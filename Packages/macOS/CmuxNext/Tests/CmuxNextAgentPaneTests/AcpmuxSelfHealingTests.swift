import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The pieces that make an acpmux failure heal itself or say why (2026-10-18: the banner
/// said only "acpmux did not start" and daemon.log had nothing, while the daemon ran an old
/// binary an update had replaced).
struct AcpmuxSelfHealingTests {
    @Test func aReplacedBundleIsTheOnlyCauseTheAppHealsItself() {
        #expect(AcpmuxFailureCause.replacedBundle.healable)
        for cause in [AcpmuxFailureCause.foreignHome, .peerRefused, .noWebSocket, .exited, .other] {
            #expect(!cause.healable)
        }
    }

    @Test func theBannerNamesTheCause() {
        let message = AgentPaneHostError.userMessage(for: AgentPaneHostError.daemonFailed(logPath: "/l/daemon.log", cause: .exited))
        #expect(message.contains("/l/daemon.log"))
        #expect(message != AgentPaneHostError.userMessage(for: AgentPaneHostError.daemonFailed(logPath: "/l/daemon.log")))
        // A healing daemon says it restarts, not that it failed.
        #expect(!AgentPaneHostError.userMessage(for: AgentPaneHostError.daemonRestarting).contains("did not start"))
    }

    @Test func theCauseGoesToTheDaemonLogOnceInAcpmuxFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ash-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("daemon.log").path
        #expect(FileManager.default.createFile(atPath: path, contents: Data("2026-10-19T05:09:51.761075Z  INFO ready\n".utf8)))
        let log = AcpmuxFailureLog(logPath: path, now: { Date(timeIntervalSince1970: 1_792_390_000) })
        #expect(log.record(.replacedBundle, detail: "pid 8886"))
        // The page retries every few seconds: the same cause is not written again.
        #expect(!log.record(.replacedBundle, detail: "pid 8886"))
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let line = String(try #require(lines.last))
        // The error journal harvests daemon.log lines by their level word.
        #expect(line.contains("  ERROR "))
        #expect(line.contains("replaced"))
        #expect(line.contains("pid 8886"))
        #expect(line.hasPrefix("2026-"))
    }

    @Test func aZombieIsNotRunning() throws {
        // A child that exits and is not reaped yet is a zombie: kill(pid, 0) still succeeds.
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ) == 0)
        // Wait for the exit (the process table says SZOMB) without reaping it.
        var siginfo = siginfo_t()
        #expect(waitid(P_PID, id_t(pid), &siginfo, WEXITED | WNOWAIT) == 0)
        #expect(kill(pid, 0) == 0)
        #expect(!agentPaneProcessIsRunning(pid))
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        #expect(!agentPaneProcessIsRunning(pid))
        #expect(agentPaneProcessIsRunning(getpid()))
    }
}
