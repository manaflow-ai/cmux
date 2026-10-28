import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// cx-jniyz.4: an owner that stops answering while the app is connected
/// (SIGSTOP, a wedged main loop) keeps its socket open, so no EOF ever
/// reaches the connection. The store must still turn disconnected (the
/// window's and the App Store's not-connected state read it) and come back
/// once the owner answers again. p14-energy-064: the heartbeat asks only
/// after a silence, and a hidden app asks a local owner nothing until a
/// window shows.
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon, .timeLimit(.minutes(2)))
struct StoppedOwnerTests {
    /// A store on a live owner whose connection asks after 1 s of silence, 2 misses closing it.
    private struct Owner {
        let pid: pid_t
        let wake: RetryWake
        let connection: DaemonConnection
        let store: DaemonStore
        let storeTask: Task<Void, Never>
        let root: URL

        @MainActor static func start(presence: ConnectionPresence) async throws -> Owner {
            let binary = try #require(RealBinary.url)
            let id = UUID().uuidString.prefix(8).lowercased()
            let root = URL(fileURLWithPath: "/tmp/cnd-stop-\(id)")
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
            connection.heartbeat.follow(presence)
            let pid = try await connection.start().pid
            let store = DaemonStore()
            let storeTask = Task { await store.run(connection: connection) }
            try await store.waitUntil("connected") { store.connectionState.isConnected }
            return Owner(pid: pid, wake: wake, connection: connection, store: store, storeTask: storeTask, root: root)
        }

        func shutDown() async {
            storeTask.cancel()
            let current = await connection.identity?.pid
            await BranchDaemonHarness.shutDown(connection)
            if current != pid, kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func aStoppedOwnerShowsDisconnectedAndReconnectsWhenItResumes() async throws {
        let owner = try await Owner.start(presence: ConnectionPresence(shown: true))
        let store = owner.store

        kill(owner.pid, SIGSTOP)
        let noticed = await Self.holds { try await store.waitUntil("disconnected", timeout: .seconds(20)) { store.connectionState.isDisconnected } }
        kill(owner.pid, SIGCONT)
        #expect(noticed)

        owner.wake.fire()
        let resumed = await Self.holds { try await store.waitUntil("reconnected", timeout: .seconds(30)) { store.connectionState.isConnected } }
        #expect(resumed)
        await owner.shutDown()
    }

    @Test func aHiddenAppAsksAStoppedOwnerNothingUntilAWindowShows() async throws {
        let presence = ConnectionPresence(shown: false)
        let owner = try await Owner.start(presence: presence)
        let store = owner.store
        // The store's first requests are answered: a waiting request would ask on the shown silence.
        _ = await owner.connection.quietHandoff { false }

        kill(owner.pid, SIGSTOP)
        // Shown, 1 s of silence and two misses close it in about 3 s; hidden, nothing asks.
        let closedWhileHidden = await Self.holds { try await store.waitUntil("disconnected", timeout: .seconds(4)) { store.connectionState.isDisconnected } }
        #expect(!closedWhileHidden)

        presence.update(shown: true)
        let noticed = await Self.holds { try await store.waitUntil("disconnected", timeout: .seconds(20)) { store.connectionState.isDisconnected } }
        kill(owner.pid, SIGCONT)
        #expect(noticed)
        await owner.shutDown()
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
