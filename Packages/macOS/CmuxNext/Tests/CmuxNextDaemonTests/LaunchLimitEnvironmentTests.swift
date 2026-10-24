import CmuxNextCompat
@testable import CmuxNextDaemon
import Testing

/// `CMUX_TUI_HOST_NOFILE_SOFT` (the open-file limit cmux was launched with) is for cmux-tui
/// owners only (pl-cef-tab-nofile review 1): a stray copy in the login shell's or the app's own
/// environment (an app started from a shell that inherited it) must not reach a terminal, where a
/// cmux-tui started in it would take the stray value as its own launch limit.
struct LaunchLimitEnvironmentTests {
    static let key = OpenFileLimit.originalSoftLimitKey

    @Test func aStrayLaunchLimitNeverReachesATerminal() {
        let stray = ["PATH": "/usr/bin:/bin", Self.key: "256"]
        #expect(TerminalEnvironment.instance.terminal(login: stray, base: stray)[Self.key] == nil)
        #expect(TerminalEnvironment.instance.terminal(login: nil, base: stray)[Self.key] == nil)
    }

    /// The daemon's own base environment drops a stray copy too; only the app's
    /// `daemonEnvironment` (joined after this filter, `DaemonLauncher.forApp`) gives the daemon one.
    @Test func aStrayLaunchLimitNeverReachesTheDaemonsBaseEnvironment() {
        let stray = ["PATH": "/usr/bin:/bin", Self.key: "256"]
        #expect(TerminalEnvironment.instance.daemon(login: stray, base: stray, overrides: [:])[Self.key] == nil)
    }
}
