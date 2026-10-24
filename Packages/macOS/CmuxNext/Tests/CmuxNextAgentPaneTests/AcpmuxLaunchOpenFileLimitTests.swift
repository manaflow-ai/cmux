import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The acpmux daemon the app starts gets the open-file limit the app was launched with, not the
/// app's raised one (pl-cef-tab-nofile review 2): `main` raises the app's soft limit to 65536 for
/// Chromium, and the daemon inherited it, so every agent and agent tool shell it ran saw 65536
/// where a terminal sees 256. `posix_spawn` cannot set a child's limits; the launch shell sets it
/// before the daemon's `exec` (``AcpmuxDaemonLauncher/script``).
@Suite(.serialized)
struct AcpmuxLaunchOpenFileLimitTests {
    /// RLIM_INFINITY (<sys/resource.h>, a macro Swift does not import).
    static let unlimited: rlim_t = (1 << 63) - 1

    /// This test process's soft limit, which a spawned daemon inherits without a launch limit.
    static func softLimit() throws -> rlim_t {
        var limit = rlimit()
        try #require(getrlimit(RLIMIT_NOFILE, &limit) == 0)
        return limit.rlim_cur
    }

    /// A stand-in `acpmux` that names the soft limit it started with (`ulimit -n`) as its ready
    /// line's token, and runs it in a child shell, as an agent's tool shell inherits it.
    static func environment(launchOpenFileLimit: rlim_t?) throws -> AcpmuxEnvironment {
        let root = URL(fileURLWithPath: "/tmp/alf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let acpmux = root.appendingPathComponent("acpmux")
        let body = #"""
        #!/bin/sh
        limit=$(/bin/sh -c 'ulimit -n')
        echo "{\"ready\":true,\"pid\":1,\"webUrl\":\"http://127.0.0.1:4567/?token=$limit\"}" >&3
        """#
        try (body + "\n").write(to: acpmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acpmux.path)
        var environment = AcpmuxEnvironment(executable: acpmux, home: home, socketPath: home.appendingPathComponent("s.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        environment.launchOpenFileLimit = launchOpenFileLimit
        return environment
    }

    /// The app raised its limit at launch: the daemon, and the shells it starts, see the launch one.
    @Test func theDaemonStartsAtTheAppsLaunchLimit() async throws {
        let launch: rlim_t = 128
        try #require(try Self.softLimit() > launch, "this process's soft limit must be above \(launch)")
        let endpoint = try await AcpmuxDaemonLauncher.launch(try Self.environment(launchOpenFileLimit: launch),
                                                             deadline: .seconds(20))
        #expect(endpoint.token == String(launch))
    }

    /// A launch that raised nothing names no launch limit: the daemon inherits the app's limit.
    @Test func withoutALaunchLimitTheDaemonInheritsTheAppsLimit() async throws {
        let soft = try Self.softLimit()
        let endpoint = try await AcpmuxDaemonLauncher.launch(try Self.environment(launchOpenFileLimit: nil),
                                                             deadline: .seconds(20))
        #expect(endpoint.token == (soft == Self.unlimited ? "unlimited" : String(soft)))
    }
}
