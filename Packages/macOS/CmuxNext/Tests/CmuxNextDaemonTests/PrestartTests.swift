import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// The first connect starts at the top of `main` (`DaemonPrestart`), in
/// parallel with AppKit, and a running daemon is reached through its
/// remembered socket without spawning `cmux-tui server status`.
@Suite(.timeLimit(.minutes(1))) struct PrestartTests {
    static let quiet = DaemonConnection.Configuration(terminalEnvironment: nil)

    @Test func aPrestartedAttemptIsTheFirstConnection() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let launcher = DaemonLauncher(
            configuration: .init(binary: URL(fileURLWithPath: "/nonexistent/cmux-tui"), session: "t", rememberedSocket: server.path),
            environment: { [:] })
        let prestart = DaemonPrestart(launcher: launcher, configuration: Self.quiet)
        let made = Mutex(0)
        let result = await DaemonStartup.shared.connect(clock: ImmediateClock(), first: { await prestart.outcome() }) {
            made.withLock { $0 += 1 }
            return DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: Self.quiet)
        } onFailure: { _ in }
        let (connection, identity) = try #require(result)
        #expect(identity.session == "t")
        #expect(await connection.isReady)
        #expect(made.withLock { $0 } == 0, "the startup loop made its own connection although the prestart connected")
        await connection.close()
    }

    @Test func aFailedPrestartIsRetriedByTheStartupLoop() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let failures = Mutex<[DaemonError]>([])
        let result = await DaemonStartup.shared.connect(clock: ImmediateClock(), first: {
            .failure(.launchFailed("exit 1: the detached session owner did not become ready"))
        }) {
            DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: Self.quiet)
        } onFailure: { error in
            failures.withLock { $0.append(error) }
        }
        let (connection, _) = try #require(result)
        #expect(failures.withLock { $0.count } == 1)
        await connection.close()
    }

    @Test func aRememberedSocketSkipsServerStatusOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (binary, log) = try LauncherWarmStartTests().fakeBinary(running: true, in: directory)
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "s", stateDirectory: directory.appendingPathComponent("state"),
                                 rememberedSocket: server.path),
            environment: { [:] })
        #expect(try await launcher.endpointProvider().socketPath == server.path)
        #expect(!FileManager.default.fileExists(atPath: log.path), "server status ran although the remembered socket answered")
        // Every later request (a retry's new connection, or a reconnect)
        // asks the daemon's owner: a hung daemon behind a live socket must
        // not keep the startup loop away from `ensure`.
        #expect(try await launcher.endpointProvider().socketPath == "/tmp/s.sock")
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n") == ["status"])
    }

    @Test func aStaleRememberedSocketFallsBackToServerStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prestart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (binary, log) = try LauncherWarmStartTests().fakeBinary(running: true, in: directory)
        // A file that is not a listening socket (a killed daemon's leftover).
        let stale = directory.appendingPathComponent("stale.sock")
        try Data().write(to: stale)
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "s", stateDirectory: directory.appendingPathComponent("state"),
                                 rememberedSocket: stale.path),
            environment: { [:] })
        #expect(try await launcher.endpointProvider().socketPath == "/tmp/s.sock")
        #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n") == ["status"])
    }

    @Test func theSocketMemoryIsPerSession() {
        let suite = "prestart-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        nonisolated(unsafe) let shared = defaults
        let memory = DaemonSocketMemory(defaults: { shared })
        memory.record("/tmp/a.sock", session: "cmux-app-a")
        #expect(memory.socket(session: "cmux-app-a") == "/tmp/a.sock")
        #expect(memory.socket(session: "cmux-app-b") == nil)
        memory.record(nil, session: "cmux-app-a")
        #expect(memory.socket(session: "cmux-app-a") == nil)
    }
}
