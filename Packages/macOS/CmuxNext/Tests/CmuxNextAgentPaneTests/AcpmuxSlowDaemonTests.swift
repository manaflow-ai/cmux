import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A slow acpmux is not a dead one (rule R5: no timer decides correctness). Under load (Austin,
/// 2026-10-29: about 80 agents, load 150 to 252) acpmux answered after the app's 2 s status
/// deadline, and the app stopped it (SIGTERM, then SIGKILL) and started another, which reloaded
/// every session and made the load worse. The app restarts acpmux only when the process exited;
/// a request that is slow waits for its answer (the pane shows that it is connecting).
///
/// No suite time limit: every wait here ends on a signal (an answer, the daemon's exit, this
/// test's kill), and a loaded runner stalls a whole test process for minutes.
@Suite(.serialized)
struct AcpmuxSlowDaemonTests {
    /// A daemon that answers `_acpmux/status` 5 s late (every other method at once). The handshake
    /// waits for it and connects to the endpoint it names; nothing is stopped or started.
    @Test func aDaemonThatAnswersAfterFiveSecondsIsWaitedFor() async throws {
        let root = URL(fileURLWithPath: "/tmp/asd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The server here is this test process, so the server peer check of the endpoint call
        // must find this process's executable: the environment names it. An attached daemon
        // (another app's) is only read: no person key, no enrollment, never a start.
        let environment = AcpmuxEnvironment(executable: try Self.ownExecutable(), home: home,
                                            socketPath: home.appendingPathComponent("s.sock").path,
                                            daemonArguments: [], childEnvironment: [:]).attached(to: home)
        let daemon = try SlowDaemon(socketPath: environment.socketPath, home: home.path, statusDelay: .seconds(5))
        defer { daemon.stop() }
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), resolve: { environment })

        let started = ContinuousClock.now
        let handshake = try await host.reconnectHandshake(sessionId: "s")
        #expect(handshake.connection?.url.port == 9, "the handshake did not connect to the slow daemon's endpoint")
        #expect(ContinuousClock.now - started >= .seconds(5), "the status reply came before the daemon sent it")
        #expect(daemon.methods.filter { $0 == "_acpmux/status" }.count >= 1)
        #expect(daemon.methods.allSatisfy { ["initialize", "_acpmux/status"].contains($0) }, "sent \(daemon.methods)")
    }

    /// This app's own daemon, alive and listening but never answering, is kept while the pane
    /// asks again and again (each attempt waits for its answer). The old watch stopped it after
    /// three missed 2 s status calls spanning 20 s and a 5 s confirm, about 27 s in; this test
    /// watches for 45 s of wall clock because that watch ran on the real clock.
    @Test(.enabled(if: CopiedListenerProbe.runs, "Needs a copied nc listener, which this Mac ends at exec: https://github.com/manaflow-ai/cmux/issues/30978"))
    func aDaemonThatDoesNotAnswerIsNeverStopped() async throws {
        let fixture = try OwnedFixture()
        let silent = try await fixture.silentDaemon()
        defer { fixture.remove(silent) }
        try fixture.writePidFile(silent.processIdentifier)
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment)

        // The pane's loop: a handshake, and another as soon as one ends.
        // task-owner: cancelled and awaited below, before the daemon is killed
        let attempts = Task {
            while !Task.isCancelled { _ = try? await host.reconnectHandshake(sessionId: nil) }
        }
        let end = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < end, agentPaneProcessIsRunning(silent.processIdentifier), !fixture.launched {
            try await Task.sleep(for: .milliseconds(250))
        }
        let stillRunning = agentPaneProcessIsRunning(silent.processIdentifier)
        let launched = fixture.launched
        attempts.cancel()
        // Its exit ends the attempt that waits on it.
        kill(silent.processIdentifier, SIGKILL)
        await attempts.value
        #expect(stillRunning, "a daemon that was slow to answer was stopped")
        #expect(!launched, "a second daemon was started beside a running one")
        #expect(!fixture.log.contains("stopped answering"), "the failure log says the daemon was restarted for not answering")
    }

    /// The daemon exited (its `daemon.pid` names a process that is gone, nothing listens): the
    /// next handshakes start it again, once for all the panes that ask at the same moment.
    @Test func aDaemonThatExitedIsStartedAgainOnce() async throws {
        let fixture = try OwnedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.writePidFile(try await Self.exitedPid())
        let host = AcpmuxHost(daemons: AcpmuxLocalDaemons(), environment: fixture.environment)

        async let first = host.reconnectHandshake(sessionId: nil)
        async let second = host.reconnectHandshake(sessionId: nil)
        _ = (try? await first, try? await second)
        #expect(fixture.launches == 1, "the exited daemon was started \(fixture.launches) times")
    }

    // MARK: - Fixtures

    /// The path of this test process's executable (`proc_pidpath`).
    static func ownExecutable() throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        return URL(fileURLWithPath: String(cString: buffer))
    }

    /// The pid of a process that has exited and was reaped.
    static func exitedPid() async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let ended = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in ended.continuation.finish() }
        try process.run()
        for await _ in ended.stream {}
        return process.processIdentifier
    }

    /// A home this app owns, whose bundled `acpmux` is a stand-in that only records each launch
    /// (one line in `launches`) and exits.
    struct OwnedFixture {
        let root: URL
        let environment: AcpmuxEnvironment
        var launched: Bool { launches > 0 }
        var launches: Int {
            let text = (try? String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").count
        }
        var log: String { (try? String(contentsOfFile: environment.logPath, encoding: .utf8)) ?? "" }

        init() throws {
            root = URL(fileURLWithPath: "/tmp/asd-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            let home = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let acpmux = bin.appendingPathComponent("acpmux")
            try "#!/bin/sh\necho launch >> '\(root.path)/launches'\nexit 1\n".write(to: acpmux, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
            environment = try #require(AcpmuxEnvironment.resolve(
                build: nil, bundledBinDirectory: bin,
                environment: ["ACPMUX_HOME": home.path, "ACPMUX_SOCKET": home.appendingPathComponent("s.sock").path],
                executableOverride: nil))
            // The failure log appends to an existing daemon.log only.
            FileManager.default.createFile(atPath: environment.logPath, contents: nil)
        }

        func writePidFile(_ pid: Int32) throws {
            try "\(pid)\n".write(to: environment.home.appendingPathComponent("daemon.pid"), atomically: true, encoding: .utf8)
        }

        /// An `acpmux` that listens on this home's socket and reads, but never answers: `nc`
        /// copied (and signed ad hoc) to a file named `acpmux`, so it is this home's daemon by
        /// every check the app makes before it signals one. `ended` gets the signal that ended it
        /// (0: it exited), once Foundation reaped it.
        func silentDaemon(ended: (@Sendable (Int32) -> Void)? = nil) async throws -> Process {
            let directory = root.appendingPathComponent("silent", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("acpmux")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/nc"), to: executable)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // macOS 27 kills a copied system binary at exec; signed ad hoc, the copy runs.
            process.arguments = ["-c", #"/usr/bin/codesign -f -s - "$0" 2>/dev/null; exec "$0" -dklU "$1""#,
                                 executable.path, environment.socketPath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if let ended {
                process.terminationHandler = { process in
                    ended(process.terminationReason == .uncaughtSignal ? process.terminationStatus : 0)
                }
            }
            try process.run()
            // A load-tolerant wait for the listener; it stops early if the daemon exited.
            let deadline = ContinuousClock.now + .seconds(60)
            while AcpmuxServerPeer.socketPeer(socketPath: environment.socketPath)?.pid != process.processIdentifier,
                  process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(AcpmuxServerPeer.socketPeer(socketPath: environment.socketPath)?.pid == process.processIdentifier)
            return process
        }

        func remove(_ daemon: Process) {
            kill(daemon.processIdentifier, SIGKILL)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A unix socket served by this test process that answers `_acpmux/status` (a status of
    /// `home`) after `statusDelay` and every other request at once, and records each method.
    nonisolated final class SlowDaemon: Sendable {
        private let descriptor: Int32
        private let path: String
        private let recorded = Mutex<[String]>([])
        var methods: [String] { recorded.withLock { $0 } }

        init(socketPath: String, home: String, statusDelay: Duration) throws {
            path = socketPath
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            self.descriptor = descriptor
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: socketPath.utf8)
                buffer[socketPath.utf8.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(descriptor, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
            Thread.detachNewThread { [self] in
                while true {
                    let client = accept(descriptor, nil, nil)
                    guard client >= 0 else { return }
                    var noSigPipe: Int32 = 1
                    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                    let connection = Connection(client)
                    Thread.detachNewThread { self.serve(connection, home: home, statusDelay: statusDelay) }
                }
            }
        }

        private func serve(_ connection: Connection, home: String, statusDelay: Duration) {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(connection.descriptor, &chunk, chunk.count, 0)
                guard count > 0 else { return connection.hangUp() }
                buffer += Data(chunk[0..<count])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let id = (object["id"] as? NSNumber)?.intValue else { continue }
                    let method = object["method"] as? String ?? ""
                    recorded.withLock { $0.append(method) }
                    let result: [String: Any] = method == "_acpmux/status"
                        ? ["webUrl": "http://127.0.0.1:9/?token=t", "pid": Int(getpid()), "build": "slow",
                           "agentHosts": true, "home": home,
                           "peers": [["name": "dev-box", "transport": "ssh", "connected": true, "state": "connected"]]]
                        : [:]
                    guard var data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
                    else { continue }
                    data.append(0x0A)
                    if method == "_acpmux/status" {
                        connection.later()
                        let reply = data
                        let seconds = Double(statusDelay.components.seconds)
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                            connection.send(reply, delayed: true)
                        }
                    } else {
                        connection.send(data, delayed: false)
                    }
                }
            }
        }

        /// One accepted connection: closed once the client hung up and every delayed reply went.
        nonisolated final class Connection: Sendable {
            let descriptor: Int32
            private struct State {
                var open = true
                var pending = 0
                var hungUp = false
            }
            private let state = Mutex(State())

            init(_ descriptor: Int32) { self.descriptor = descriptor }

            func later() { state.withLock { $0.pending += 1 } }

            func send(_ data: Data, delayed: Bool) {
                state.withLock { state in
                    if state.open { _ = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, data.count, 0) } }
                    if delayed { state.pending -= 1 }
                    closeIfDone(&state)
                }
            }

            func hangUp() {
                state.withLock { state in
                    state.hungUp = true
                    closeIfDone(&state)
                }
            }

            private func closeIfDone(_ state: inout State) {
                guard state.open, state.hungUp, state.pending == 0 else { return }
                state.open = false
                close(descriptor)
            }
        }

        func stop() {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
            unlink(path)
        }
    }
}
