import CmuxControlSocket
import CmuxSettings
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

    private struct State {
        var breadcrumbs: [String] = []
        var failures: [FailureEvent] = []
        var started: [(path: String, generation: UInt64)] = []
        var recordedPaths: [String] = []
        var pathMissing: [(path: String, generation: UInt64)] = []
        var rearms: [(generation: UInt64, errnoCode: Int32, consecutiveFailures: Int, delayMs: Int)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var breadcrumbs: [String] { state.withLock { $0.breadcrumbs } }
    var failures: [FailureEvent] { state.withLock { $0.failures } }
    var started: [(path: String, generation: UInt64)] { state.withLock { $0.started } }
    var recordedPaths: [String] { state.withLock { $0.recordedPaths } }
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

@MainActor
private struct ServerHarness: ~Copyable {
    let directory: URL
    let socketPath: String
    let recorder: ServerEventRecorder
    let server: SocketControlServer

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
        recorder = ServerEventRecorder()
        server = SocketControlServer(
            initialSocketPath: socketPath,
            events: recorder.makeEvents()
        )
    }

    /// Stops the listener and removes the scratch directory. Tests defer
    /// this explicitly; a deinit cannot call the main-actor `stop()`.
    func shutdown() {
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

private extension Int32 {
    var peerIsClosed: Bool {
        var descriptor = pollfd(fd: self, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        return descriptor.revents & Int16(POLLHUP) != 0
    }
}

extension AsyncStream where Element == ControlConnection {
    /// Awaits the next yielded connection with a timeout so a broken accept
    /// path fails the test instead of hanging it.
    fileprivate func nextConnection(timeout: TimeInterval = 5.0) async -> ControlConnection? {
        await withTaskGroup(of: ControlConnection?.self) { group in
            group.addTask {
                var iterator = self.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
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

@MainActor
@Suite("SocketControlServer lifecycle")
struct SocketControlServerLifecycleTests {
    @Test func startBindsListensAndReportsHealth() throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
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

    @Test func acceptsClientAndCapturesPeerPid() async throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        let fd = connect(to: harness.socketPath)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }

        let connection = try #require(await server.connections.nextConnection())
        defer { close(connection.socket) }
        #expect(connection.peerProcessID == getpid())
    }

    @Test func connectionStreamSpansListenerRestarts() async throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
        let server = harness.server

        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        let firstClient = connect(to: harness.socketPath)
        #expect(firstClient >= 0)
        defer { if firstClient >= 0 { close(firstClient) } }
        let first = try #require(await server.connections.nextConnection())
        close(first.socket)

        server.stop()
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        let secondClient = connect(to: harness.socketPath)
        #expect(secondClient >= 0)
        defer { if secondClient >= 0 { close(secondClient) } }
        let second = try #require(await server.connections.nextConnection())
        close(second.socket)
        #expect(second.peerProcessID == getpid())
    }

    @Test func connectionStreamBoundsPendingDescriptors() async throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        let clients = (0..<33).map { _ in connect(to: harness.socketPath) }
        defer { clients.filter { $0 >= 0 }.forEach { close($0) } }
        #expect(clients.allSatisfy { $0 >= 0 })

        #expect(waitUntil { clients[32].peerIsClosed })

        for _ in 0..<32 {
            let connection = try #require(await server.connections.nextConnection())
            close(connection.socket)
        }
    }

    @Test func stopUnlinksSocketAndClearsState() throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
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
        defer { harness.shutdown() }
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
        defer { harness.shutdown() }
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
        defer { harness.shutdown() }
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
        defer { harness.shutdown() }
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
        defer { harness.shutdown() }
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

@MainActor
@Suite("SocketControlServer startup reservation")
struct SocketControlServerReservationTests {
    @Test func reservationIsConsumedByStart() throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
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
        defer { harness.shutdown() }
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        let other = harness.directory.appendingPathComponent("other.sock").path
        #expect(server.reserveStartupSocketPath(other) == other)
        // The running listener's path is unchanged.
        #expect(server.currentSocketPath == harness.socketPath)
    }
}

@MainActor
@Suite("SocketControlServer path monitor")
struct SocketControlServerPathMonitorTests {
    @Test func detectsDeletedSocketPathAndSupportsRestart() throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
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
        defer { harness.shutdown() }
        let server = harness.server
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))
        let generation = try #require(harness.recorder.started.first?.generation)
        server.stop()
        #expect(!server.shouldRestartForMissingPath(path: harness.socketPath, generation: generation))
    }
}

// Deliberate test gap, stated per repo policy: the accept-failure
// suspend/backoff/resume path (SocketRecoveryClock consumer, AcceptRecoveryState
// latch) needs accept(2) to fail with a hot errno. Forcing EMFILE requires
// lowering RLIMIT_NOFILE process-wide, which races the other suites running
// in-process under Swift Testing's parallel executor, so a deterministic
// behavior test is not practical here. The nearest contracts are pinned
// instead: claim-after-stop rejection below, and stop()'s resume-before-cancel
// is exercised by every harness shutdown.
@MainActor
@Suite("SocketControlServer rearm")
struct SocketControlServerRearmTests {
    @Test func claimWithoutPendingRearmReturnsNil() throws {
        let harness = try ServerHarness()
        defer { harness.shutdown() }
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
