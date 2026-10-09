@testable import CmuxNextApp
import CmuxNextAgentActivity
import CmuxNextSettings
import Darwin
import Foundation
import Synchronization
import Testing

/// The helper v2 (`computerUse.driver = "upstream"`): started with
/// responsibility disclaimed and the Cua Driver environment, configured over
/// its stdin, stopped by closing stdin; the default driver (legacy) never
/// starts it.
@MainActor
@Suite(.serialized) struct ComputerUseHelperV2Tests {
    /// Records spawns; answers `configure` with `ready` like the real helper.
    final class FakeSpawner: ComputerUseHelperV2Spawning, Sendable {
        struct Spawn: Sendable {
            var executable: URL
            var environment: [String: String]
            var child: ComputerUseHelperV2Child
            var helperInput: Int32
        }

        let spawns = Mutex<[Spawn]>([])
        let terminated = Mutex<[pid_t]>([])
        let answersReady: Bool

        init(answersReady: Bool = true) { self.answersReady = answersReady }

        func spawn(executable: URL, environment: [String: String], logPath: String) throws -> ComputerUseHelperV2Child {
            var toHelper: [Int32] = [-1, -1]
            var toHost: [Int32] = [-1, -1]
            pipe(&toHelper)
            pipe(&toHost)
            let child = ComputerUseHelperV2Child(pid: 31337, input: toHelper[1],
                                                 lines: DisclaimedHelperSpawner.lines(from: toHost[0]))
            let helperRead = toHelper[0]
            let helperWrite = toHost[1]
            let answersReady = self.answersReady
            // The fake helper: read `configure`, answer `ready` with its socket.
            let thread = Thread {
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(helperRead, &bytes, bytes.count)
                if answersReady, count > 0,
                   let line = bytes[0..<count].split(separator: 0x0A).first,
                   let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                   let socket = message["socket"] as? String {
                    let ready = ComputerUseHelperV2.line(["type": "ready", "protocol": 1, "pid": 31337, "socket": socket])
                    _ = ready.withUnsafeBytes { write(helperWrite, $0.baseAddress, $0.count) }
                }
            }
            thread.start()
            spawns.withLock { $0.append(Spawn(executable: executable, environment: environment, child: child, helperInput: helperRead)) }
            return child
        }

        func terminate(_ pid: pid_t) { terminated.withLock { $0.append(pid) } }
    }

    nonisolated static let helperApp = URL(fileURLWithPath: "/tmp/cmux DEV v2.app/Contents/Library/cmux Computer Use (dev).app")

    static func helper(_ spawner: FakeSpawner, app: URL? = helperApp) -> ComputerUseHelperV2 {
        let directory = "/tmp/cuv2-\(UUID().uuidString.prefix(8))/s"
        return ComputerUseHelperV2(directory: directory, helperApp: { app }, spawner: spawner,
                                   readyTimeout: .seconds(5), exitGrace: .zero)
    }

    @Test func theSpawnEnvironmentTurnsOffTelemetryAndUpdateChecksAndBoundsTheWindowWait() {
        let environment = ComputerUseHelperV2.environment(home: "/Users/u", temporaryDirectory: "/tmp/u/", user: "u")
        #expect(environment["CUA_DRIVER_RS_TELEMETRY_ENABLED"] == "0")
        #expect(environment["CUA_TELEMETRY_ENABLED"] == "false")
        #expect(environment["CUA_DRIVER_RS_UPDATE_CHECK"] == "false")
        #expect(environment["CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS"] == "100")
        #expect(environment["CUA_DRIVER_HOST_BUNDLE_ID"] == "com.cmuxterm.cua.dev")
        #expect(!environment.keys.contains { $0.hasPrefix("CMUX") }, "no cmux token or socket reaches the helper")
    }

    @Test func onSpawnsTheEmbeddedHelperAndWritesThePrivateEndpoint() async throws {
        let spawner = FakeSpawner()
        let helper = Self.helper(spawner)
        defer { try? FileManager.default.removeItem(atPath: (helper.directory as NSString).deletingLastPathComponent) }

        await helper.apply(enabled: true)

        let spawn = try #require(spawner.spawns.withLock { $0.first })
        #expect(spawn.executable.path == Self.helperApp.path + "/Contents/MacOS/cmux-cua-helper")
        #expect(spawn.environment == ComputerUseHelperV2.environment())
        #expect(helper.state == .running(31337))
        var info = stat()
        #expect(lstat(helper.endpointPath, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        var directory = stat()
        #expect(lstat(helper.directory, &directory) == 0)
        #expect(directory.st_mode & 0o777 == 0o700)
        let endpoint = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: helper.endpointPath))) as? [String: Any])
        #expect(endpoint["socket"] as? String == helper.socketPath)
        #expect((endpoint["secret"] as? String)?.count == 64)

        await helper.apply(enabled: false)
        #expect(helper.state == .off)
        #expect(access(helper.endpointPath, F_OK) != 0, "the endpoint goes away with the helper")
        // stdin closed: the fake helper's read end sees EOF.
        var byte: UInt8 = 0
        #expect(read(spawn.helperInput, &byte, 1) == 0)
    }

    @Test func offSpawnsNothing() async {
        let spawner = FakeSpawner()
        let helper = Self.helper(spawner)
        await helper.apply(enabled: false)
        #expect(spawner.spawns.withLock { $0.isEmpty })
        #expect(helper.state == .off)
    }

    @Test func aBuildWithoutTheDevHelperIsUnavailable() async {
        let spawner = FakeSpawner()
        let helper = Self.helper(spawner, app: nil)
        await helper.apply(enabled: true)
        #expect(spawner.spawns.withLock { $0.isEmpty })
        guard case .unavailable = helper.state else { Issue.record("expected unavailable"); return }
    }

    @Test func aHelperThatNeverReportsReadyIsStoppedAndUnavailable() async {
        let spawner = FakeSpawner(answersReady: false)
        let directory = "/tmp/cuv2-\(UUID().uuidString.prefix(8))/s"
        let helper = ComputerUseHelperV2(directory: directory, helperApp: { Self.helperApp }, spawner: spawner,
                                         readyTimeout: .milliseconds(200), exitGrace: .zero)
        await helper.apply(enabled: true)
        #expect(spawner.terminated.withLock { $0 } == [31337])
        guard case .unavailable = helper.state else { Issue.record("expected unavailable"); return }
    }

    /// Required test 5: the default driver (legacy) changes nothing; the
    /// helper v2 never starts and the legacy helper starts as before.
    @Test func theDefaultLegacyDriverNeverStartsTheV2Helper() async throws {
        #expect(ComputerUseSettings().driver == .legacy)
        var on = ComputerUseSettings()
        on.enabled = true
        #expect(ComputerUseHelperDaemon.route(ComputerUseSettings(), disabledByPolicy: false) == (false, false))
        #expect(ComputerUseHelperDaemon.route(on, disabledByPolicy: false) == (true, false))
        #expect(ComputerUseHelperDaemon.route(on, disabledByPolicy: true) == (false, false))
        var upstream = on
        upstream.driver = .upstream
        #expect(ComputerUseHelperDaemon.route(upstream, disabledByPolicy: false) == (false, true))

        let launcher = ComputerUseHelperDaemonTests.FakeLauncher()
        let spawner = FakeSpawner()
        let id = UUID().uuidString.prefix(8)
        let socket = "/tmp/cu-d-\(id)/s/cua.sock"
        let daemon = ComputerUseHelperDaemon(identity: CuaHelperIdentity { $0 == ComputerUseHelperDaemonTests.nightly },
                                             candidates: { [ComputerUseHelperDaemonTests.nightly] }, launcher: launcher,
                                             socketPath: socket,
                                             stateDirectory: FileManager.default.temporaryDirectory.appending(path: "cu-state-\(id)"),
                                             upstream: Self.helper(spawner))
        defer { daemon.stop() }
        await daemon.apply(on, disabledByPolicy: false)
        #expect(spawner.spawns.withLock { $0.isEmpty })
        let launch = try #require(launcher.launches.first)
        #expect(launch.arguments == ComputerUseHelperDaemon.arguments(socketPath: socket, ownerPID: launch.arguments.contains("--owner-pid") ? getpid() : nil))
        #expect(Set(daemon.childEnvironment.keys) == ["CMUX_NEXT_CUA_SOCKET", "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"])

        // Switching to upstream stops the legacy helper, then starts v2.
        await daemon.apply(upstream, disabledByPolicy: false)
        #expect(launcher.terminated == [4242])
        #expect(spawner.spawns.withLock { $0.count } == 1)
        #expect(daemon.upstream.state == .running(31337))
        await daemon.upstream.apply(enabled: false)
    }

    @Test func spawningWithoutTheDisclaimCallRefusesToStart() {
        let spawner = DisclaimedHelperSpawner(disclaim: nil)
        #expect(throws: DisclaimedHelperSpawner.Failure.disclaimUnavailable) {
            try spawner.spawn(executable: URL(fileURLWithPath: "/usr/bin/true"), environment: [:], logPath: "/dev/null")
        }
    }

    @Test func theSystemProvidesTheDisclaimCall() {
        #expect(DisclaimedHelperSpawner.systemDisclaim != nil)
    }

    /// The spawner asks for the disclaim, and closing stdin is the liveness
    /// signal (`/bin/cat` exits at EOF like the helper).
    @Test func theSpawnerDisclaimsAndClosingStdinEndsTheChild() throws {
        let recorder: DisclaimedHelperSpawner.DisclaimFunction = { _, value in
            ComputerUseHelperV2Tests.disclaimRequests.withLock { $0.append(value) }
            return 0
        }
        Self.disclaimRequests.withLock { $0 = [] }
        let child = try DisclaimedHelperSpawner(disclaim: recorder)
            .spawn(executable: URL(fileURLWithPath: "/bin/cat"), environment: [:], logPath: "/dev/null")
        #expect(Self.disclaimRequests.withLock { $0 } == [1])
        child.closeInput()
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(5)
        var reaped: pid_t = 0
        while reaped == 0, Date() < deadline {
            reaped = waitpid(child.pid, &status, WNOHANG)
            if reaped == 0 { usleep(10_000) }
        }
        if reaped == 0 { kill(child.pid, SIGKILL); waitpid(child.pid, &status, 0) }
        #expect(reaped == child.pid)
    }

    nonisolated static let disclaimRequests = Mutex<[Int32]>([])
}
