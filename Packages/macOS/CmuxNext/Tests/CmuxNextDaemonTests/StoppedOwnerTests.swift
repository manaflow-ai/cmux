import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// cx-jniyz.4: an owner that stops answering while the app is connected
/// (SIGSTOP, a wedged main loop) keeps its socket open, so no EOF ever
/// reaches the connection. The store must still turn disconnected (the
/// window's and the App Store's not-connected state read it) and come back
/// once the owner answers again.
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon, .timeLimit(.minutes(2)))
struct StoppedOwnerTests {
    @Test func aStoppedOwnerShowsDisconnectedAndReconnectsWhenItResumes() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-stop-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:])
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: "cnd-stop-\(id)", stateDirectory: root.appendingPathComponent("state")),
            environment: { environment })
        _ = try await launcher.ensure()
        let wake = RetryWake(owner: "StoppedOwnerTests")
        var configuration = DaemonConnection.Configuration(retryWake: wake)
        configuration.heartbeat = .seconds(1)
        configuration.heartbeatMisses = 2
        configuration.localHeartbeat = true
        let connection = DaemonConnection(configuration: configuration, endpointProvider: launcher.endpointProvider)
        let owner = try await connection.start().pid
        let store = await DaemonStore()
        let storeTask = Task { await store.run(connection: connection) }
        try await store.waitUntil("connected") { store.connectionState.isConnected }

        kill(owner, SIGSTOP)
        let noticed = await Self.holds { try await store.waitUntil("disconnected", timeout: .seconds(20)) { store.connectionState.isDisconnected } }
        kill(owner, SIGCONT)
        #expect(noticed)

        wake.fire()
        let resumed = await Self.holds { try await store.waitUntil("reconnected", timeout: .seconds(30)) { store.connectionState.isConnected } }
        #expect(resumed)

        storeTask.cancel()
        let current = await connection.identity?.pid
        await BranchDaemonHarness.shutDown(connection)
        if current != owner, kill(owner, 0) == 0 { kill(owner, SIGKILL) }
    }

    private static func holds(_ wait: () async throws -> Void) async -> Bool {
        do {
            try await wait()
            return true
        } catch {
            return false
        }
    }
}

private extension DaemonConnectionState {
    var isConnected: Bool { if case .connected = self { true } else { false } }
    var isDisconnected: Bool { if case .disconnected = self { true } else { false } }
}
