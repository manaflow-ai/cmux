import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The leftover daemon idle exit (acpmux `daemon_lifecycle.rs`) keeps the daemon while its app
/// runs: the spawn environment names this app's pid in `ACPMUX_OWNER_APP_PID`.
struct AcpmuxOwnerAppPidTests {
    @Test func theSpawnEnvironmentNamesThisApp() throws {
        let (environment, root) = try AcpmuxAgentPairGuardTests.environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let variables = AcpmuxDaemonLauncher.spawnEnvironment(
            environment, inherited: ["ACPMUX_OWNER_APP_PID": "1"])
        #expect(variables["ACPMUX_OWNER_APP_PID"] == String(ProcessInfo.processInfo.processIdentifier))
    }
}
