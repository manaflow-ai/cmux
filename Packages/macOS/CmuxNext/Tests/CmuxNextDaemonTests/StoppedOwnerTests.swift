import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// cx-jniyz.4: an owner that stops answering while the app is connected
/// (SIGSTOP, a wedged main loop) keeps its socket open, so no EOF ever
/// reaches the connection. The connection must notice (its heartbeat marks the
/// daemon not answering) and, as the P0 of 2026-10-30 requires, must not end:
/// the owner's process is alive, so the store stays connected and a request sent
/// while it is stopped gets its reply once it answers again, on the same
/// connection. p14-energy-064: the heartbeat asks only
/// after a silence, and a hidden app asks a local owner nothing until a
/// window shows.
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon, .timeLimit(.minutes(2)))
struct StoppedOwnerTests {
    /// A store on a live owner whose connection asks after 1 s of silence, 2 misses marking it not answering.
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

    @Test func aStoppedOwnerShowsNotAnsweringAndItsRequestsCompleteWhenItResumes() async throws {
        let owner = try await Owner.start(presence: ConnectionPresence(shown: true))
        let store = owner.store
        let connection = owner.connection

        kill(owner.pid, SIGSTOP)
        // Sent while the owner is stopped, with no client deadline (as a create waits for its daemon); it goes out
        // well before SIGCONT, which waits for at least two missed asks below.
        let pending = Task { try await connection.request(IdentifyRequest(), timeout: nil) }
        let noticed = await Self.holds { try await Self.waitUntil(seconds: 20) { !connection.daemonAnswering } }
        let stayedConnected = await store.connectionState.isConnected
        kill(owner.pid, SIGCONT)
        #expect(noticed, "the heartbeat did not mark a stopped owner not answering")
        #expect(stayedConnected, "a live owner's connection ended")

        let answered = try await pending.value
        #expect(answered.pid == owner.pid, "the request sent while stopped was answered by another daemon")
        let resumed = await Self.holds { try await Self.waitUntil(seconds: 20) { connection.daemonAnswering } }
        #expect(resumed, "the owner answers again but the connection still says it does not")
        #expect(await store.connectionState.isConnected)
        await owner.shutDown()
    }

    @Test func aHiddenAppAsksAStoppedOwnerNothingUntilAWindowShows() async throws {
        let presence = ConnectionPresence(shown: false)
        let owner = try await Owner.start(presence: presence)
        let connection = owner.connection
        // The store's first requests are answered: a waiting request would ask on the shown silence.
        _ = await owner.connection.quietHandoff { false }

        kill(owner.pid, SIGSTOP)
        // Shown, 1 s of silence and two misses mark it in about 3 s; hidden, nothing asks.
        let noticedWhileHidden = await Self.holds { try await Self.waitUntil(seconds: 4) { !connection.daemonAnswering } }
        #expect(!noticedWhileHidden)

        presence.update(shown: true)
        let noticed = await Self.holds { try await Self.waitUntil(seconds: 20) { !connection.daemonAnswering } }
        kill(owner.pid, SIGCONT)
        #expect(noticed)
        await owner.shutDown()
    }

    /// Polls `condition` every 50 ms for at most `seconds`; throws when it never held.
    private static func waitUntil(seconds: Int, _ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<(seconds * 20) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
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
}
