import Testing
@testable import CmuxNextDaemon

/// The daemon owns the settings file (cmux-tui-core `mux/settings.rs`): an app
/// launched on `CMUX_NEXT_CONFIG_FILE` (a tagged build, a test rig's isolated
/// config) must start its daemon on the same file, or the two read and write
/// different settings (the terminal sizing policy rig, PR #24650, found the
/// daemon on `~/.config/cmux/cmux-next.json`). Terminals still never inherit
/// the app's `CMUX_NEXT_*` launch knobs.
struct DaemonEnvironmentConfigFileTests {
    private let base = ["HOME": "/Users/rig", "CMUX_NEXT_CONFIG_FILE": "/rig/cmux-next.json", "CMUX_NEXT_NO_ACTIVATE": "1"]

    @Test func theDaemonGetsTheAppsSettingsFile() {
        let daemon = TerminalEnvironment.instance.daemon(login: ["PATH": "/usr/bin"], base: base, overrides: [:])
        #expect(daemon["CMUX_NEXT_CONFIG_FILE"] == "/rig/cmux-next.json")
        #expect(daemon["CMUX_NEXT_NO_ACTIVATE"] == nil)
    }

    @Test func terminalsDoNotInheritIt() {
        let terminal = TerminalEnvironment.instance.terminal(login: ["PATH": "/usr/bin"], base: base)
        #expect(terminal["CMUX_NEXT_CONFIG_FILE"] == nil)
    }
}
