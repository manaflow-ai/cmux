@testable import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import CmuxNextCompat
import Testing

@Suite(.serialized) struct ControlSocketServerTests {
    func makeServer(_ mode: ControlAccessMode, path: String = temporarySocketPath(), trustedAncestor: pid_t = getpid()) throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        router.updateCatalog(sampleCatalog())
        let server = ControlSocketServer(
            configuration: .init(
                path: path,
                accessMode: mode,
                trustedAncestor: trustedAncestor
            ),
            router: router
        )
        try server.start()
        return server
    }

    @Test func servesV1AndV2Lines() throws {
        let server = try makeServer(.automation)
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        #expect(client.send("ping") == "PONG")
        #expect(client.send("auth whatever") == "OK: Authentication not required")
        let identify = try client.call("system.identify")
        #expect(identify["id"] == "t1")
        #expect(identify["result"]?["app"] == "cmux-next")
        #expect(identify["result"]?["socket_path"] == .string(server.configuration.path))
        #expect(identify["result"]?["access_mode"] == "automation")
        let run = try client.call("action.run", ["action": "tab-group create", "args": ["name": "X", "color": "green"], "wait": false])
        #expect(run["ok"] == true)
        // The CLI's capability and automation envelopes are unwrapped.
        #expect(client.send("_cmux_capability_v1 abc ping") == "PONG")
        #expect(client.send("__cmux_automation_origin e30= ping") == "PONG")
        // Many requests on one connection keep their order.
        for index in 0..<50 {
            let line = JSONValue.object(["id": JSONValue(index), "method": "system.ping"]).compactText
            let response = try JSONValue.parse(Data(client.send(line).utf8))
            #expect(response["id"] == JSONValue(index))
        }
    }

    @Test func socketFilePermissionsFollowTheMode() throws {
        for mode in [ControlAccessMode.cmuxOnly, .automation] {
            let server = try makeServer(mode)
            defer { server.stop() }
            var info = stat()
            #expect(lstat(server.configuration.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600, "\(mode)")
        }
    }

    @Test func cmuxOnlyAdmitsDescendantsOnly() throws {
        // This test process is its own "app": admitted.
        let admitted = try makeServer(.cmuxOnly)
        defer { admitted.stop() }
        #expect(try LineClient(path: admitted.configuration.path).send("ping") == "PONG")

        // A trusted ancestor that is not our ancestor: denied, then closed.
        let denied = try makeServer(.cmuxOnly, trustedAncestor: 999_999)
        defer { denied.stop() }
        let client = try LineClient(path: denied.configuration.path)
        #expect(client.send("ping") == ControlAuthorizer.accessDenied)
        #expect(client.readLine() == "")
    }

    @Test func neverStealsALiveSocketButReclaimsStaleOnes() throws {
        let path = temporarySocketPath()
        let first = try makeServer(.automation, path: path)
        #expect(throws: ControlSocketServer.StartError.addressInUse(path)) { _ = try makeServer(.automation, path: path) }
        #expect(try LineClient(path: path).send("ping") == "PONG")
        first.stop()
        #expect(access(path, F_OK) != 0, "stop removes the socket it created")

        // A stale socket file from a crashed run is reclaimed.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        let second = try makeServer(.automation, path: path)
        defer { second.stop() }
        #expect(try LineClient(path: path).send("ping") == "PONG")

        // A regular file is never deleted.
        let regular = temporarySocketPath()
        FileManager.default.createFile(atPath: regular, contents: Data("keep".utf8))
        defer { unlink(regular) }
        #expect(throws: ControlSocketServer.StartError.pathOccupied(regular)) { _ = try makeServer(.automation, path: regular) }
    }

    @Test func halfClosedClientStillGetsItsResponse() throws {
        let server = try makeServer(.automation)
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        let line = Array(#"{"id":1,"method":"action.list"}"#.utf8) + [0x0A]
        _ = line.withUnsafeBytes { write(client.descriptor, $0.baseAddress, $0.count) }
        shutdown(client.descriptor, SHUT_WR)
        let response = try JSONValue.parse(Data(client.readLine().utf8))
        #expect(response["result"]?["count"] == 4)
    }

    @Test func offModeDoesNotStart() {
        let server = ControlSocketServer(
            configuration: .init(path: temporarySocketPath(), accessMode: .off),
            router: ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        )
        #expect(throws: ControlSocketServer.StartError.disabled) { try server.start() }
    }
}

/// Idle wakeups (plans/cmux-next/idle-wakeups.md): accept never spins.
@Suite(.serialized) struct ControlSocketAcceptTests {
    /// Regression: on EMFILE/ENFILE `accept` fails while the connection
    /// stays in the backlog, so the level-triggered read source fired again
    /// at once: 100% CPU on the accept queue until descriptors freed up.
    @Test func descriptorExhaustionBacksOffInsteadOfSpinning() async throws {
        let calls = Atomic<Int>(0)
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(
            configuration: .init(path: temporarySocketPath(), accessMode: .automation),
            router: router,
            accept: { _ in
                calls.add(1, ordering: .relaxed)
                errno = EMFILE
                return -1
            }
        )
        try server.start()
        defer { server.stop() }
        // A connection waits in the backlog, so the listener stays readable.
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: server.configuration.path.utf8)
            buffer[server.configuration.path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)
        try await Task.sleep(for: .milliseconds(500))
        // Backoff from 50 ms: a handful of attempts in 500 ms, not thousands.
        #expect(calls.load(ordering: .relaxed) <= 10)
    }
}

/// `start` used to set the PROCESS-WIDE umask to 0177 around bind(2), so a
/// file another thread created in that window got mode 0600 (it broke a
/// watcher test and could hit the app at launch). The socket must get its
/// mode without process-wide state.
@Suite(.serialized) struct ControlSocketUmaskTests {
    private static func createdMode(_ path: String) -> mode_t? {
        let file = open(path, O_CREAT | O_WRONLY | O_EXCL, 0o644)
        guard file >= 0 else { return nil }
        close(file)
        defer { unlink(path) }
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : nil
    }

    @Test(arguments: [ControlAccessMode.cmuxOnly, .automation])
    func aFileCreatedWhileTheSocketBindsKeepsItsNormalMode(_ mode: ControlAccessMode) throws {
        let probe = "/tmp/cnc-probe-\(UUID().uuidString.prefix(8).lowercased())"
        let expected = try #require(Self.createdMode(probe), "the reference file could not be created")
        let seen = Mutex<[mode_t?]>([])
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(
            configuration: .init(path: temporarySocketPath(), accessMode: mode),
            router: router,
            accept: { Darwin.accept($0, nil, nil) },
            bind: { descriptor, address, length in
                // Another thread's file create, landing while the socket file is created.
                let mode = Self.createdMode(probe)
                seen.withLock { $0.append(mode) }
                return Darwin.bind(descriptor, address, length)
            }
        )
        try server.start()
        defer { server.stop() }

        let modes = seen.withLock { $0 }
        #expect(!modes.isEmpty)
        #expect(modes.allSatisfy { $0 == expected }, "a concurrent create got \(modes), expected \(expected)")
        var info = stat()
        #expect(lstat(server.configuration.path, &info) == 0)
        #expect(info.st_mode & 0o777 == mode.filePermissions, "the socket still gets its own mode")
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
    }
}

/// The socket file deleted under a running app (a host's /tmp sweeper removed
/// `/tmp/cmux-debug-<tag>.sock` at the same hour two nights running on a soak
/// mini): the app kept its listener, but nothing could connect again until a
/// relaunch. The server puts its socket back, with its mode, and never takes a
/// path another server holds.
@Suite(.serialized) struct ControlSocketPathRestoreTests {
    func makeServer(_ mode: ControlAccessMode, path: String) throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        router.updateCatalog(sampleCatalog())
        let server = ControlSocketServer(configuration: .init(path: path, accessMode: mode), router: router)
        try server.start()
        return server
    }

    /// Pings until a connect succeeds or `limit` passes.
    func pingWithin(_ path: String, _ limit: Duration) async -> String? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let client = try? LineClient(path: path) { return client.send("ping") }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test func aDeletedSocketFileComesBackWithItsMode() async throws {
        let path = temporarySocketPath()
        let server = try makeServer(.automation, path: path)
        defer { server.stop() }
        let open = try LineClient(path: path)
        #expect(open.send("ping") == "PONG")

        #expect(unlink(path) == 0)
        #expect(await pingWithin(path, .seconds(5)) == "PONG", "a new connect reaches the server again")
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == ControlAccessMode.automation.filePermissions)
        #expect(open.send("ping") == "PONG", "a connection open across the delete keeps working")

        // Deleted again: restored again.
        #expect(unlink(path) == 0)
        #expect(await pingWithin(path, .seconds(5)) == "PONG")
        server.stop()
        #expect(access(path, F_OK) != 0, "stop removes the restored socket")
    }

    /// Restart CLI Listener (`palette.restartSocketListener`): the listener is
    /// closed and bound again at the same path with the same mode, so a new
    /// connect reaches the server and the socket file is the server's own.
    @Test func restartBindsTheListenerAgainAtItsPath() throws {
        let path = temporarySocketPath()
        let server = try makeServer(.automation, path: path)
        defer { server.stop() }
        #expect(try LineClient(path: path).send("ping") == "PONG")
        var before = stat()
        #expect(lstat(path, &before) == 0)

        try server.restart()

        #expect(server.isRunning)
        var after = stat()
        #expect(lstat(path, &after) == 0)
        #expect(after.st_mode & S_IFMT == S_IFSOCK)
        #expect(after.st_mode & 0o777 == ControlAccessMode.automation.filePermissions)
        #expect(after.st_ino != before.st_ino, "the socket file was not bound again")
        #expect(try LineClient(path: path).send("ping") == "PONG", "a new connect does not reach the restarted server")
        server.stop()
        #expect(access(path, F_OK) != 0, "stop after a restart leaves the socket file behind")
    }

    /// A listening socket at `path` that is not a ``ControlSocketServer`` (no watch of its own).
    func plainListener(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(descriptor, 8) == 0)
        return descriptor
    }

    func inode(_ path: String) -> ino_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_ino : nil
    }

    @Test func aPathAnotherServerTookIsLeftAlone() async throws {
        let path = temporarySocketPath()
        let first = try makeServer(.automation, path: path)
        defer { first.stop() }
        // Another server's socket replaces the file in one rename, so there is
        // no moment with nothing at the path for the first server to fill.
        let other = temporarySocketPath()
        let listener = try plainListener(at: other)
        defer { close(listener) }
        let taken = try #require(inode(other))
        #expect(rename(other, path) == 0)
        try await Task.sleep(for: .milliseconds(500))
        #expect(inode(path) == taken, "the first server leaves the path alone")
        first.stop()
        #expect(inode(path) == taken, "stopping the first never removes the other socket")
        unlink(path)
    }

    /// A quit landing while a restore is binding: the restore's new listener
    /// is closed and its file removed, without a crash.
    @Test func aStopDuringARestoreClosesTheNewSocket() async throws {
        let path = temporarySocketPath()
        let binds = Mutex(0)
        let box = Mutex<ControlSocketServer?>(nil)
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(
            configuration: .init(path: path, accessMode: .automation),
            router: router,
            accept: { Darwin.accept($0, nil, nil) },
            bind: { descriptor, address, length in
                let result = Darwin.bind(descriptor, address, length)
                let count = binds.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count == 2 { box.withLock { $0 }?.stop() }  // the restore's bind
                return result
            }
        )
        box.withLock { $0 = server }
        defer { box.withLock { $0 = nil } }
        try server.start()
        #expect(unlink(path) == 0)
        let deadline = ContinuousClock.now + .seconds(5)
        while binds.withLock({ $0 }) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(binds.withLock { $0 } == 2, "the delete started one restore")
        #expect(!server.isRunning)
        #expect(access(path, F_OK) != 0, "the restored socket of a stopped server is removed")
    }

    /// Restores that keep failing (descriptors exhausted while the file is
    /// gone) back off instead of spinning, and the socket still comes back
    /// once a bind works again.
    @Test func restoresThatKeepFailingBackOffAndStillComeBack() async throws {
        let path = temporarySocketPath()
        let binds = Mutex(0)
        let failing = Mutex(true)
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(
            configuration: .init(path: path, accessMode: .automation),
            router: router,
            accept: { Darwin.accept($0, nil, nil) },
            bind: { descriptor, address, length in
                let count = binds.withLock { count -> Int in
                    count += 1
                    return count
                }
                if count > 1, failing.withLock({ $0 }) {
                    errno = EACCES
                    return -1
                }
                return Darwin.bind(descriptor, address, length)
            }
        )
        try server.start()
        defer { server.stop() }
        #expect(unlink(path) == 0)
        try await Task.sleep(for: .seconds(2))
        let failed = binds.withLock { $0 } - 1
        #expect(failed >= 3, "the delete started restores (\(failed))")
        #expect(failed <= 12, "failed restores back off instead of spinning (\(failed) in 2 s)")
        failing.withLock { $0 = false }
        #expect(await pingWithin(path, .seconds(10)) == "PONG", "the socket comes back once a bind works")
    }
}
