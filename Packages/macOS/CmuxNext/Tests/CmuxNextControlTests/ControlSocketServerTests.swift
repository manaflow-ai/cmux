@testable import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import Synchronization
import Testing

@Suite(.serialized) struct ControlSocketServerTests {
    func makeServer(_ mode: ControlAccessMode, path: String = temporarySocketPath(), trustedAncestor: pid_t = getpid(), password: String? = nil) throws -> ControlSocketServer {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        router.updateCatalog(sampleCatalog())
        let server = ControlSocketServer(
            configuration: .init(
                path: path,
                accessMode: mode,
                passwordVerifier: password.map { expected in { @Sendable in $0 == expected } },
                trustedAncestor: trustedAncestor
            ),
            router: router
        )
        try server.start()
        return server
    }

    @Test func servesV1AndV2Lines() throws {
        let server = try makeServer(.allowAll)
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        #expect(client.send("ping") == "PONG")
        #expect(client.send("auth whatever") == "OK: Authentication not required")
        let identify = try client.call("system.identify")
        #expect(identify["id"] == "t1")
        #expect(identify["result"]?["app"] == "cmux-next")
        #expect(identify["result"]?["socket_path"] == .string(server.configuration.path))
        #expect(identify["result"]?["access_mode"] == "allowAll")
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
        for (mode, expected) in [(ControlAccessMode.cmuxOnly, mode_t(0o600)), (.allowAll, 0o666)] {
            let server = try makeServer(mode)
            defer { server.stop() }
            var info = stat()
            #expect(lstat(server.configuration.path, &info) == 0)
            #expect(info.st_mode & 0o777 == expected, "\(mode)")
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

    @Test func passwordModeRequiresLogin() throws {
        let server = try makeServer(.password, password: "hunter2")
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        let blocked = try client.call("action.list")
        #expect(blocked["error"]?["code"] == "auth_required")
        #expect(client.send("auth nope") == "ERROR: Invalid password")
        #expect(client.send("auth hunter2") == "OK: Authenticated")
        #expect(try client.call("action.list")["ok"] == true)

        let v2 = try LineClient(path: server.configuration.path)
        #expect(try v2.call("auth.login", ["password": "bad"])["error"]?["code"] == "auth_failed")
        #expect(try v2.call("auth.login", ["password": "hunter2"])["ok"] == true)
        #expect(try v2.call("system.ping")["ok"] == true)
    }

    @Test func neverStealsALiveSocketButReclaimsStaleOnes() throws {
        let path = temporarySocketPath()
        let first = try makeServer(.allowAll, path: path)
        #expect(throws: ControlSocketServer.StartError.addressInUse(path)) { _ = try makeServer(.allowAll, path: path) }
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
        let second = try makeServer(.allowAll, path: path)
        defer { second.stop() }
        #expect(try LineClient(path: path).send("ping") == "PONG")

        // A regular file is never deleted.
        let regular = temporarySocketPath()
        FileManager.default.createFile(atPath: regular, contents: Data("keep".utf8))
        defer { unlink(regular) }
        #expect(throws: ControlSocketServer.StartError.pathOccupied(regular)) { _ = try makeServer(.allowAll, path: regular) }
    }

    @Test func halfClosedClientStillGetsItsResponse() throws {
        let server = try makeServer(.allowAll)
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
            router: ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
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
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let server = ControlSocketServer(
            configuration: .init(path: temporarySocketPath(), accessMode: .allowAll),
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

    @Test(arguments: [ControlAccessMode.cmuxOnly, .allowAll])
    func aFileCreatedWhileTheSocketBindsKeepsItsNormalMode(_ mode: ControlAccessMode) throws {
        let probe = "/tmp/cnc-probe-\(UUID().uuidString.prefix(8).lowercased())"
        let expected = try #require(Self.createdMode(probe), "the reference file could not be created")
        let seen = Mutex<[mode_t?]>([])
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
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
