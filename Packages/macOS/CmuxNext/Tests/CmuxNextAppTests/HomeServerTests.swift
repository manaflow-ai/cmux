@testable import CmuxNextApp
import Dispatch
import Foundation
import Testing

/// Home's local mux server, with a stand-in `mux` script: Home waits for
/// its ready line, the server ends when the app stops it (stdin closes),
/// and a missing or silent `mux` never leaves Home waiting forever.
@MainActor
struct HomeServerTests {
    private static func directory(script: String?) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("home-server-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let script {
            let path = directory + "/mux"
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return directory
    }

    private static func server(_ directory: String, timeout: Duration = .seconds(30)) -> HomeServer {
        HomeServer(environment: { ["PATH": directory + ":/usr/bin:/bin"] }, readyTimeout: timeout, home: directory)
    }

    /// Watches `pid` (kqueue) from now; arm it while the process surely runs.
    private nonisolated static func exitWatch(of pid: Int32) -> Task<Void, Never> {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        let exited = AsyncStream<Void> { continuation in
            source.setEventHandler { @Sendable in continuation.finish() }
        }
        source.resume()
        return Task {
            for await _ in exited {}
            source.cancel()
        }
    }

    @Test func readyLineStartsHomeAndStopEndsTheServer() async throws {
        // Like `mux home`: ready line first, then run until stdin closes.
        let directory = try Self.directory(script: "#!/bin/sh\n[ \"$1\" = home ] || exit 2\necho 'mux home: ready http://127.0.0.1:1'\nexec cat >/dev/null\n")
        let server = Self.server(directory)
        await server.ensureRunning()
        let pid = try #require(server.processIdentifier)
        #expect(kill(pid, 0) == 0)
        await server.ensureRunning()
        #expect(server.processIdentifier == pid)
        let exited = Self.exitWatch(of: pid)
        server.stop()
        await exited.value
    }

    @Test func serverGetsIdentityKeysAndNoTerminalSessionKeys() {
        let env = HomeServer.serverEnvironment(
            terminal: ["PATH": "/bin", "TERM": "xterm-ghostty", "ZDOTDIR": "/x", "PWD": "/", "CMUX_SOCKET_PATH": "/tmp/s.sock", "HOME": "/h"],
            app: ["HOME": "/other", "USER": "u", "LOGNAME": "u", "TMPDIR": "/t/"])
        #expect(env == ["PATH": "/bin", "CMUX_SOCKET_PATH": "/tmp/s.sock", "HOME": "/h", "USER": "u", "LOGNAME": "u",
                        "TMPDIR": "/t/", "MUX_EXIT_ON_STDIN_EOF": "1"])
    }

    @Test func missingMuxReturnsAtOnce() async throws {
        let server = Self.server(try Self.directory(script: nil))
        await server.ensureRunning()
        #expect(server.processIdentifier == nil)
    }

    @Test func serverThatExitsBeforeReadyReturns() async throws {
        let server = Self.server(try Self.directory(script: "#!/bin/sh\necho 'address in use' >&2\nexit 1\n"))
        await server.ensureRunning()
        #expect(server.processIdentifier == nil)
    }

    @Test func silentServerMissesTheDeadlineAndKeepsRunning() async throws {
        let server = Self.server(try Self.directory(script: "#!/bin/sh\nexec cat >/dev/null\n"), timeout: .milliseconds(200))
        await server.ensureRunning()
        let pid = try #require(server.processIdentifier)
        // Retry loads the page again; it does not start a second server.
        await server.ensureRunning()
        #expect(server.processIdentifier == pid)
        let exited = Self.exitWatch(of: pid)
        server.stop()
        await exited.value
    }
}
