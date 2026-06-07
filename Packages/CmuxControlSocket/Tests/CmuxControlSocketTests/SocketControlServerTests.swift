import CmuxControlSocket
import CmuxSettings
import CmuxSocketControl
import Darwin
import Foundation
import os
import Testing

/// Thread-safe recorder for the server's event seam.
private final class ServerEventRecorder: Sendable {
    struct FailureEvent {
        let message: String
        let stage: String
        let errnoCode: Int32?
    }

    struct ClientEvent {
        let socket: Int32
        let peerPid: pid_t?
    }

    private struct State {
        var breadcrumbs: [String] = []
        var failures: [FailureEvent] = []
        var started: [(path: String, generation: UInt64)] = []
        var recordedPaths: [String] = []
        var clients: [ClientEvent] = []
        var pathMissing: [(path: String, generation: UInt64)] = []
        var rearms: [(generation: UInt64, errnoCode: Int32, consecutiveFailures: Int, delayMs: Int)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Closes accepted client sockets after recording unless disabled.
    let closesAcceptedClients: Bool

    init(closesAcceptedClients: Bool = true) {
        self.closesAcceptedClients = closesAcceptedClients
    }

    var breadcrumbs: [String] { state.withLock { $0.breadcrumbs } }
    var failures: [FailureEvent] { state.withLock { $0.failures } }
    var started: [(path: String, generation: UInt64)] { state.withLock { $0.started } }
    var recordedPaths: [String] { state.withLock { $0.recordedPaths } }
    var clients: [ClientEvent] { state.withLock { $0.clients } }
    var pathMissing: [(path: String, generation: UInt64)] { state.withLock { $0.pathMissing } }
    var rearms: [(generation: UInt64, errnoCode: Int32, consecutiveFailures: Int, delayMs: Int)] {
        state.withLock { $0.rearms }
    }

    func makeEvents() -> SocketControlServerEvents {
        SocketControlServerEvents(
            breadcrumb: { message, _ in
                self.state.withLock { $0.breadcrumbs.append(message) }
            },
            failure: { message, stage, errnoCode, _ in
                self.state.withLock {
                    $0.failures.append(FailureEvent(message: message, stage: stage, errnoCode: errnoCode))
                }
            },
            listenerDidStart: { path, generation in
                self.state.withLock { $0.started.append((path: path, generation: generation)) }
            },
            recordLastSocketPath: { path in
                self.state.withLock { $0.recordedPaths.append(path) }
            },
            clientAccepted: { socket, peerPid in
                self.state.withLock { $0.clients.append(ClientEvent(socket: socket, peerPid: peerPid)) }
                if self.closesAcceptedClients {
                    close(socket)
                }
            },
            pathMissingDetected: { path, generation in
                self.state.withLock { $0.pathMissing.append((path: path, generation: generation)) }
            },
            rearmRequested: { generation, errnoCode, consecutiveFailures, delayMs in
                self.state.withLock {
                    $0.rearms.append((
                        generation: generation,
                        errnoCode: errnoCode,
                        consecutiveFailures: consecutiveFailures,
                        delayMs: delayMs
                    ))
                }
            }
        )
    }
}

private struct ServerHarness: ~Copyable {
    let directory: URL
    let socketPath: String
    let recorder: ServerEventRecorder
    let server: SocketControlServer

    init(closesAcceptedClients: Bool = true) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
        recorder = ServerEventRecorder(closesAcceptedClients: closesAcceptedClients)
        server = SocketControlServer(
            initialSocketPath: socketPath,
            events: recorder.makeEvents()
        )
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Polls `predicate` every 10ms for up to `timeout` seconds. Deterministic
/// test-side waiting for DispatchSource-driven events.
private func waitUntil(
    timeout: TimeInterval = 5.0,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        usleep(10_000)
    }
    return predicate()
}

@discardableResult
private func connect(to path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let copied = path.withCString { cString -> Bool in
        let length = strlen(cString)
        guard length < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.baseAddress!.copyMemory(from: cString, byteCount: length + 1)
        }
        return true
    }
    guard copied else {
        close(fd)
        return -1
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(fd, sockaddrPointer, size)
        }
    }
    guard result == 0 else {
        close(fd)
        return -1
    }
    return fd
}

@Suite("SocketControlServer lifecycle")
struct SocketControlServerLifecycleTests {
    @Test func startBindsListensAndReportsHealth() throws {
        let harness = try ServerHarness()
        let server = harness.server

        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(server.isRunning)
        #expect(server.accessMode == .cmuxOnly)
        #expect(server.currentSocketPath == harness.socketPath)
        #expect(server.activeSocketPath(preferredPath: "/tmp/other.sock") == harness.socketPath)
        #expect(server.currentSocketPathForRemoteRestore() == harness.socketPath)
        #expect(harness.recorder.started.count == 1)
        #expect(harness.recorder.recordedPaths == [harness.socketPath])
        #expect(harness.recorder.breadcrumbs.contains("socket.listener.listening"))

        let health = server.listenerHealth(expectedSocketPath: harness.socketPath)
        #expect(health.isRunning)
        #expect(health.socketPathMatches)
        #expect(health.socketPathExists)
        #expect(health.socketPathOwnedByListener)

        // The path lock is held and marked reusable while listening.
        let lockPath = server.transport.pathLockPath(for: harness.socketPath)
        #expect(FileManager.default.fileExists(atPath: lockPath))
    }

    @Test func acceptsClientAndCapturesPeerPid() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        let fd = connect(to: harness.socketPath)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }

        #expect(waitUntil { !harness.recorder.clients.isEmpty })
        let client = try #require(harness.recorder.clients.first)
        #expect(client.peerPid == getpid())
    }

    @Test func stopUnlinksSocketAndClearsState() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(FileManager.default.fileExists(atPath: harness.socketPath))

        server.stop()

        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: harness.socketPath))
        #expect(server.currentSocketPathForRemoteRestore() == nil)
        #expect(server.activeSocketPath(preferredPath: "/tmp/pref.sock") == "/tmp/pref.sock")
        let health = server.listenerHealth(expectedSocketPath: harness.socketPath)
        #expect(!health.isRunning)
        #expect(!health.socketPathExists)
    }

    @Test func startOnSamePathIsIdempotent() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(server.start(socketPath: harness.socketPath, accessMode: .allowAll))

        // Same listener generation: no second listenerDidStart event.
        #expect(harness.recorder.started.count == 1)
        // Access mode still updates so permission/auth behavior follows settings.
        #expect(server.accessMode == .allowAll)
    }

    @Test func restartIncrementsGeneration() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        server.stop()
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        let generations = harness.recorder.started.map(\.generation)
        #expect(generations.count == 2)
        #expect(generations[1] > generations[0])
    }

    @Test func replacesStaleSocketFileAfterCrash() throws {
        let harness = try ServerHarness()
        let server = harness.server

        // Simulate a crashed previous instance: it had started listening (lock
        // marked reusable) and died without unlinking the socket. Closing the
        // descriptor drops the flock but leaves the marked lock file behind,
        // exactly like a kill -9.
        guard case .acquired(let lockFD, _) = server.transport.acquireSocketPathLock(for: harness.socketPath) else {
            Issue.record("could not acquire lock for crash simulation")
            return
        }
        server.transport.markSocketPathLockReusable(lockFD)
        close(lockFD)

        // Leave a dead socket file behind (bound but no listener process).
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(stale >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        harness.socketPath.withCString { cString in
            withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                buffer.baseAddress!.copyMemory(from: cString, byteCount: strlen(cString) + 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(stale, sockaddrPointer, size)
            }
        }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: harness.socketPath))

        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(server.isRunning)
        let fd = connect(to: harness.socketPath)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
    }

    @Test func refusesRegularFileAtSocketPath() throws {
        let harness = try ServerHarness()
        let server = harness.server
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: harness.socketPath))

        #expect(!server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(!server.isRunning)
        // The regular file is preserved, and the failure surfaced.
        #expect(FileManager.default.fileExists(atPath: harness.socketPath))
        let contents = try String(contentsOf: URL(fileURLWithPath: harness.socketPath), encoding: .utf8)
        #expect(contents == "not a socket")
        #expect(harness.recorder.failures.contains { $0.message == "socket.listener.start.failed" })
    }

    @Test func appliesAccessModePermissions() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .allowAll))

        var info = stat()
        #expect(stat(harness.socketPath, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o666)

        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(stat(harness.socketPath, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }
}

@Suite("SocketControlServer startup reservation")
struct SocketControlServerReservationTests {
    @Test func reservationIsConsumedByStart() throws {
        let harness = try ServerHarness()
        let server = harness.server

        let reserved = server.reserveStartupSocketPath(harness.socketPath)
        #expect(reserved == harness.socketPath)
        #expect(server.currentSocketPathForRemoteRestore() == harness.socketPath)
        #expect(server.activeSocketPath(preferredPath: "/tmp/pref.sock") == harness.socketPath)

        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(server.isRunning)
        let fd = connect(to: harness.socketPath)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
    }

    @Test func reservationIsRejectedWhileRunning() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        let other = harness.directory.appendingPathComponent("other.sock").path
        #expect(server.reserveStartupSocketPath(other) == other)
        // The running listener's path is unchanged.
        #expect(server.currentSocketPath == harness.socketPath)
    }
}

@Suite("SocketControlServer path monitor")
struct SocketControlServerPathMonitorTests {
    @Test func detectsDeletedSocketPathAndSupportsRestart() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        let generation = try #require(harness.recorder.started.first?.generation)

        unlink(harness.socketPath)

        #expect(waitUntil { !harness.recorder.pathMissing.isEmpty })
        let event = try #require(harness.recorder.pathMissing.first)
        #expect(event.path == harness.socketPath)
        #expect(event.generation == generation)
        #expect(harness.recorder.failures.contains { $0.message == "socket.listener.path.missing" })
        #expect(server.shouldRestartForMissingPath(path: event.path, generation: event.generation))

        // The host-side restart sequence rebinds and recreates the file.
        server.stop()
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(FileManager.default.fileExists(atPath: harness.socketPath))
        #expect(!server.shouldRestartForMissingPath(path: event.path, generation: event.generation))
        let fd = connect(to: harness.socketPath)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
    }

    @Test func staleMissingPathReportIsRejectedAfterStop() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        let generation = try #require(harness.recorder.started.first?.generation)
        server.stop()
        #expect(!server.shouldRestartForMissingPath(path: harness.socketPath, generation: generation))
    }
}

@Suite("SocketControlServer rearm")
struct SocketControlServerRearmTests {
    @Test func claimWithoutPendingRearmReturnsNil() throws {
        let harness = try ServerHarness()
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        #expect(server.claimPendingRearm(
            generation: 1,
            errnoCode: EMFILE,
            consecutiveFailures: 3,
            delayMs: 100
        ) == nil)
    }
}
