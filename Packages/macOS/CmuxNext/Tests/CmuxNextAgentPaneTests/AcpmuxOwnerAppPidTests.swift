import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Quit leaves no helper processes: the daemon follows the app that started it (acpmux
/// `daemon/owner_exit.rs`). The spawn environment names this app's pid in `ACPMUX_OWNER_APP_PID`,
/// over any value the app inherited (an app launched from another cmux's terminal).
struct AcpmuxOwnerAppPidTests {
    @Test func theSpawnEnvironmentNamesThisApp() throws {
        let (environment, root) = try AcpmuxAgentPairGuardTests.environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let variables = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: ["ACPMUX_OWNER_APP_PID": "1"])
        #expect(variables["ACPMUX_OWNER_APP_PID"] == String(ProcessInfo.processInfo.processIdentifier))
    }

    /// A Team-signed spawn inherits only process basics, and still names its app.
    @Test func aSignedSpawnNamesThisAppToo() throws {
        var (environment, root) = try AcpmuxAgentPairGuardTests.environment()
        defer { try? FileManager.default.removeItem(at: root) }
        environment.passesPersonKeyAtSpawn = false
        let variables = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: ["ACPMUX_OWNER_APP_PID": "1"])
        #expect(variables["ACPMUX_OWNER_APP_PID"] == String(ProcessInfo.processInfo.processIdentifier))
    }

    /// The daemon carries none of the app's launch identity (bundle id, launchd job and instance):
    /// it outlives the app, and an update relaunch must not end it with the app (hq#6338).
    @Test func theSpawnEnvironmentCarriesNoAppLaunchIdentity() throws {
        let (environment, root) = try AcpmuxAgentPairGuardTests.environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let inherited = [
            "__CFBundleIdentifier": "com.cmuxterm.app.debug", "XPC_SERVICE_NAME": "application.com.cmuxterm.app.debug.1.2",
            "XPC_FLAGS": "0x0", "LaunchInstanceID": "ABC", "LANG": "en_US.UTF-8",
        ]
        let variables = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: inherited)
        for key in AcpmuxDaemonLauncher.appLaunchIdentityKeys {
            #expect(variables[key] == nil, "\(key) reached the daemon")
        }
        #expect(variables["LANG"] == "en_US.UTF-8")
    }
}
