@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextControl
import Foundation
import Testing

/// cx-c6xdh at the app's acpmux spawn: the daemon this app starts for its agent chats gets what
/// this app's terminals get for `cmux`, the bundled CLI and the control socket naming this app,
/// so an agent in a chat runs this app's `cmux` (acpmux puts it first on the agent's `PATH`) and
/// reaches this app.
@Suite
struct AgentChatCLIEnvironmentTests {
    @Test func theAgentChatDaemonGetsThisAppsCLIAndSocket() throws {
        let bin = URL(fileURLWithPath: "/Applications/cmux DEV cli.app/Contents/Resources/bin", isDirectory: true)
        let launch = LaunchIdentity(bundleID: "com.cmuxterm.app.next.debug.cli", tag: "cli",
                                    socketPath: "/tmp/cmux-next-debug-cli.sock")
        let environment = try #require(AgentTabPaneSource.paneEnvironment(
            tag: "cli", bundledBinDirectory: bin, environment: ["PATH": "/usr/bin:/bin"],
            launch: launch, isExecutable: { _ in true }))
        let spawn = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: ["PATH": "/usr/bin:/bin"])
        #expect(spawn["CMUX_BUNDLED_CLI_PATH"] == bin.appendingPathComponent("cmux").path)
        #expect(spawn["CMUX_SOCKET_PATH"] == "/tmp/cmux-next-debug-cli.sock")
        #expect(spawn["CMUX_BUNDLE_ID"] == "com.cmuxterm.app.next.debug.cli")
        #expect(spawn["CMUX_TAG"] == "cli")
    }

    @Test func aBuildWithoutABundledCLINamesNone() throws {
        let launch = LaunchIdentity(bundleID: "com.cmuxterm.app.next", tag: nil, socketPath: "/tmp/cmux-next.sock")
        let environment = try #require(AgentTabPaneSource.paneEnvironment(
            tag: nil, bundledBinDirectory: nil, environment: ["PATH": "/usr/bin:/bin"],
            launch: launch, isExecutable: { _ in true }))
        let spawn = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: [:])
        #expect(spawn["CMUX_BUNDLED_CLI_PATH"] == nil)
        #expect(spawn["CMUX_SOCKET_PATH"] == "/tmp/cmux-next.sock")
    }
}
