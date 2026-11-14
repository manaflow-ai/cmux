import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// An app launched on its own settings file (`CMUX_NEXT_CONFIG_FILE` in its
/// `LSEnvironment`, a tagged dogfood build) hands that file to every terminal,
/// to its daemon and to the acpmux daemon its agents run under. Before, the
/// app read and wrote the override, but `TerminalEnvironment` drops every
/// `CMUX_NEXT_*` key of the app's environment, so a Claude Code started in the
/// app's terminal ran `cmux mcp serve` on the shared cmux-next.json, found
/// `agents.cmuxMcp` off there and exited before the MCP handshake (Claude
/// showed CONNECTION_CLOSED right after the person chose Add to My Agents).
struct LaunchConfigFileEnvironmentTests {
    static let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    static func launch(_ process: [String: String]) -> LaunchIdentity {
        LaunchIdentity.resolve(bundleID: "com.cmuxterm.app.debug.cu-fresh", bundledEnvironment: process,
                               processEnvironment: process, isDebugBuild: true, home: home)
    }

    @Test func theOverrideKeyIsTheOneTheAppReads() {
        #expect(LaunchIdentity.configFileKey == CmuxConfigFile.overrideKey)
    }

    @Test func aLaunchOnItsOwnSettingsFileGivesItToTerminalsTheDaemonAndAgents() async {
        let process = [CmuxConfigFile.overrideKey: "~/.config/cmux/cmux-next-cu-fresh.json"]
        let launch = Self.launch(process)
        let expected = "/Users/someone/.config/cmux/cmux-next-cu-fresh.json"
        #expect(launch.terminalEnvironment[CmuxConfigFile.overrideKey] == expected, "absolute, as every reader expands it")

        // Every local terminal (the per-terminal `env` provider) and the daemon process, which
        // passes its own environment to terminals created without one: the app's overrides win
        // over the filtered app environment, which forwards no `CMUX_NEXT_*` knob itself.
        let terminal = await TerminalEnvironment.instance.shared(base: process, overrides: launch.terminalEnvironment,
                                                                 login: { [:] })()
        #expect(terminal[CmuxConfigFile.overrideKey] == expected)
        let daemon = TerminalEnvironment.instance.daemon(login: [:], base: process, overrides: launch.terminalEnvironment)
        #expect(daemon[CmuxConfigFile.overrideKey] == expected)
    }

    @Test func anAbsoluteOverrideIsKeptAsGiven() {
        let launch = Self.launch([CmuxConfigFile.overrideKey: "/tmp/rig/cmux.json"])
        #expect(launch.terminalEnvironment[CmuxConfigFile.overrideKey] == "/tmp/rig/cmux.json")
    }

    @Test(arguments: [[:], [CmuxConfigFile.overrideKey: ""]])
    func aLaunchOnTheSharedFileSetsNothing(_ process: [String: String]) async {
        let launch = Self.launch(process)
        #expect(launch.terminalEnvironment[CmuxConfigFile.overrideKey] == nil)
        let terminal = await TerminalEnvironment.instance.shared(base: process, overrides: launch.terminalEnvironment,
                                                                 login: { [:] })()
        #expect(terminal[CmuxConfigFile.overrideKey] == nil)
    }
}
