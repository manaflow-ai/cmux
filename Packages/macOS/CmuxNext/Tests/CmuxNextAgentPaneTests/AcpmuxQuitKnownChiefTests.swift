import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextWakeups

/// A quit whose daemon socket is gone decides from the host locks and leaves out the Home Chief's
/// sessions it last read (`AcpmuxQuitProof.knownChief`). Those are per daemon home, and an end that
/// keeps nothing (NIGHTLY's Chief on the app's acpmux) leaves out none: a Chief subagent host
/// still holding its lock is then an agent still running, never "ended".
struct AcpmuxQuitKnownChiefTests {
    /// A home of its own per test: the remembered sessions are process-wide and tests run in parallel.
    private func home(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/known-chief-test-\(UUID().uuidString)/\(name)", isDirectory: true)
    }

    @Test func anEndThatKeepsNothingLeavesOutNoChiefHost() {
        let app = home("app-acpmux")
        AcpmuxQuitProof.remember(chief: ["chief-turn", "chief-sub"], home: app)
        #expect(AcpmuxQuitProof.keptChief(home: app, keep: .chief) == ["chief-turn", "chief-sub"])
        #expect(AcpmuxQuitProof.keptChief(home: app, keep: .nothing).isEmpty)
    }

    @Test func anotherDaemonsCensusDoesNotReplaceTheAppDaemonsChief() {
        let app = home("app-acpmux"), oldChief = home("chief-acpmux")
        AcpmuxQuitProof.remember(chief: ["chief-turn"], home: app)
        // The move's census of the Chief home's old daemon.
        AcpmuxQuitProof.remember(chief: ["old-chief-turn"], home: oldChief)
        #expect(AcpmuxQuitProof.keptChief(home: app, keep: .chief) == ["chief-turn"])
        #expect(AcpmuxQuitProof.keptChief(home: oldChief, keep: .chief) == ["old-chief-turn"])
    }

    // The Retry after a shutdown in progress, with the daemon gone: a Chief subagent host still
    // holds its lock. The end that keeps nothing reports it; one that keeps the Chief does not.
    @Test func aRetryWithNoSocketReportsAChiefHostStillRunningWhenNothingIsKept() async throws {
        let app = home("app-acpmux")
        let hosts = app.appendingPathComponent("hosts", isDirectory: true)
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let record = try JSONSerialization.data(withJSONObject: ["session_id": "chief-sub", "start_nonce": "n1"])
        try record.write(to: hosts.appendingPathComponent("chief-sub.n1.json"))
        let lock = hosts.appendingPathComponent("chief-sub.n1.live").path
        #expect(FileManager.default.createFile(atPath: lock, contents: nil))
        let fd = open(lock, O_RDWR | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        AcpmuxQuitProof.remember(chief: ["chief-sub"], home: app)

        let work = BackgroundWork(label: "test.quit-known-chief")
        let nothingKept = await AcpmuxQuit.withoutSocket(app, runner: work, keep: .nothing, waitForShutdown: false, within: .zero)
        #expect(nothingKept == .agentsStillRunning(["chief-sub"]))
        let chiefKept = await AcpmuxQuit.withoutSocket(app, runner: work, keep: .chief, waitForShutdown: false, within: .zero)
        #expect(chiefKept == .noDaemon)
    }
}
