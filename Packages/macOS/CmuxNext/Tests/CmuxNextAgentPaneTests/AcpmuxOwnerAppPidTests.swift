import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The leftover daemon idle exit (acpmux `daemon_lifecycle.rs`) keeps the daemon while its app
/// runs: the spawn environment names this app's pid in `ACPMUX_OWNER_APP_PID`, and carries the
/// app's daemon features so the exit turns on in a signed build too.
struct AcpmuxOwnerAppPidTests {
    @Test func theSpawnEnvironmentNamesThisApp() throws {
        let (environment, root) = try AcpmuxAgentPairGuardTests.environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let variables = AcpmuxDaemonLauncher.spawnEnvironment(
            environment, inherited: ["ACPMUX_OWNER_APP_PID": "1"])
        #expect(variables["ACPMUX_OWNER_APP_PID"] == String(ProcessInfo.processInfo.processIdentifier))
    }

    /// A Team-signed spawn inherits no feature list: the app's own daemon features reach the
    /// daemon anyway, over whatever the app inherited.
    @Test func aSignedSpawnCarriesTheAppsDaemonFeatures() throws {
        var (environment, root) = try AcpmuxAgentPairGuardTests.environment()
        defer { try? FileManager.default.removeItem(at: root) }
        environment.passesPersonKeyAtSpawn = false
        environment.daemonFeatures = ["CMUX_ENABLE_FEATURES": "leftoverDaemonIdleExit"]
        let variables = AcpmuxDaemonLauncher.spawnEnvironment(
            environment, inherited: ["CMUX_ENABLE_FEATURES": "appThing", "CMUX_DISABLE_FEATURES": "otherThing"])
        #expect(variables["CMUX_ENABLE_FEATURES"] == "leftoverDaemonIdleExit")
        #expect(variables["CMUX_DISABLE_FEATURES"] == nil)
        environment.daemonFeatures = [:]
        let off = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: ["CMUX_ENABLE_FEATURES": "x"])
        #expect(off["CMUX_ENABLE_FEATURES"] == nil)
    }
}
