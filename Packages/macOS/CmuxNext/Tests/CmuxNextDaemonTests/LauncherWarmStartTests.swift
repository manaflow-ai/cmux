import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// Connecting to a daemon that already runs must not wait for the login
/// shell (`$SHELL -l -i`, about 0.9 s on a real zsh setup): the login
/// environment only matters when `server ensure` spawns a new owner.
@Suite struct LauncherWarmStartTests {
    /// A stand-in cmux-tui: `server status` answers with `statusJSON` (or
    /// exits 3, like a missing owner), `server ensure` (with its options)
    /// logs itself and answers "started".
    final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    func fakeBinary(running isRunning: Bool, in directory: URL) throws -> (binary: URL, log: URL) {
        let log = directory.appendingPathComponent("calls.log")
        let binary = directory.appendingPathComponent("cmux-tui")
        let running = #"{"generation":"g1","message":"local server is running","pid":4242,"session":"s","socket":"/tmp/s.sock","status":"running"}"#
        let started = #"{"generation":"g2","message":"local server started","pid":4343,"session":"s","socket":"/tmp/s.sock","status":"started"}"#
        let script = """
        #!/bin/sh
        action=""; previous=""
        for arg in "$@"; do [ "$previous" = server ] && action="$arg"; previous="$arg"; done
        echo "$action" >> '\(log.path)'
        case "$action" in
          status) \(isRunning ? "echo '\(running)'; exit 0" : "echo '{\"code\":\"server.unavailable\"}'; exit 3") ;;
          ensure) echo '\(started)'; exit 0 ;;
        esac
        exit 2
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (binary, log)
    }

    func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test(.timeLimit(.minutes(1))) func aRunningDaemonIsFoundWithoutTheLoginEnvironment() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (binary, log) = try fakeBinary(running: true, in: directory)
        let loginAsked = Flag()
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "s", stateDirectory: directory.appendingPathComponent("state")),
            environment: {
                loginAsked.set()
                return ["PATH": "/usr/bin:/bin"]
            })
        let result = try await launcher.ensure()
        #expect(result.status == "running")
        #expect(result.endpoint.pid == 4242)
        #expect(!loginAsked.isSet, "the login environment was captured for a running daemon")
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(!calls.contains("ensure"), "server ensure ran for a running daemon: \(calls)")
    }

    @Test(.timeLimit(.minutes(1))) func aMissingDaemonIsStartedWithTheLoginEnvironment() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (binary, log) = try fakeBinary(running: false, in: directory)
        let loginAsked = Flag()
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "s", stateDirectory: directory.appendingPathComponent("state")),
            environment: {
                loginAsked.set()
                return ["PATH": "/usr/bin:/bin"]
            })
        let result = try await launcher.ensure()
        #expect(result.status == "started")
        #expect(loginAsked.isSet)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(calls.last == "ensure")
    }

    /// A cold launch runs `server ensure` while the login shell is still
    /// running: the daemon gets the remembered (here: the app's own)
    /// environment instead of waiting up to the capture's deadline.
    @Test(.timeLimit(.minutes(1))) func aMissingDaemonIsStartedBeforeTheLoginShellAnswers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (binary, log) = try fakeBinary(running: false, in: directory)
        let shell = SlowLoginShell()
        defer { shell.close() }
        let cache = LoginEnvironmentCache(store: MemoryLoginEnvironmentFile().store, capture: { await shell.capture($0) })
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "s", stateDirectory: directory.appendingPathComponent("state")),
            environment: DaemonLauncher.appEnvironment(cache: cache, base: ["PATH": "/usr/bin:/bin"], overrides: [:]))
        let result = try await launcher.ensure()
        #expect(result.status == "started")
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(calls.last == "ensure")
    }
}
