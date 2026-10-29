#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The oracle's `crashes.daemon`: the connection counts a ready connection the daemon dropped
/// without `daemon-shutdown`. A killed owner cannot count its own end, so the app does. Run:
/// `swift test --filter DaemonDropCountTests`.
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon)
struct DaemonDropCountTests {
    @Test func aKilledOwnerCountsOnceAndAClientCloseDoesNot() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-drop-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: ProcessInfo.processInfo.environment,
                                                                    overrides: [:])
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: "cnd-drop-\(id)", stateDirectory: root.appendingPathComponent("state")),
            environment: { environment })
        _ = try await launcher.ensure()
        let connection = DaemonConnection(configuration: .init(retryWake: RetryWake(owner: "DaemonDropCountTests")),
                                          endpointProvider: launcher.endpointProvider)
        let pid = try await connection.start().pid
        #expect(await connection.droppedWithoutShutdown == 0)
        kill(pid, SIGKILL)
        let deadline = ContinuousClock.now + .seconds(10)
        while await connection.droppedWithoutShutdown == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await connection.droppedWithoutShutdown == 1)
        _ = try await launcher.ensure()
        await BranchDaemonHarness.shutDown(connection)
        #expect(await connection.droppedWithoutShutdown == 1, "closing the connection is not a daemon end")
        if let running = await launcher.runningOwner() { kill(running.pid, SIGKILL) }
    }
}
#endif
