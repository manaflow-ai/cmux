@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemonService
import Testing

/// The open-file limit the app was launched with goes to the cmux-tui owners the app starts and
/// to no terminal (pl-cef-tab-nofile review 1). `main` raises the app's limit before it starts
/// the daemon; the daemon must give its shells the launch limit back. The launch limit used to
/// ride in `terminalEnvironment`, which is also every terminal's per-terminal `env`
/// (`TerminalEnvironment.shared(overrides:)`), so every shell carried
/// `CMUX_TUI_HOST_NOFILE_SOFT=256`, and a cmux-tui started in one took it as its own launch limit.
struct AppEnvironmentLaunchLimitTests {
    static let key = OpenFileLimit.originalSoftLimitKey
    static let raised = OpenFileLimit.Change(before: 256, after: 65_536)

    @Test func noTerminalCarriesTheLaunchLimit() {
        let environment = AppEnvironment.current([:], openFiles: Self.raised)
        #expect(environment.terminalEnvironment[Self.key] == nil)
    }

    /// The launch limit goes to the daemon's `server ensure` (with the first-party app packages),
    /// so the daemon records it and gives it back to its shells, hooks and plugins.
    @Test func theDaemonGetsTheLaunchLimit() {
        let environment = AppEnvironment.current([:], openFiles: Self.raised)
        #expect(environment.launchOpenFileLimit == 256)
        #expect(environment.daemonEnvironment == [Self.key: "256"])
        let ensure = DaemonService.ownerProcessEnvironment(launch: environment.daemonEnvironment)
        #expect(ensure[Self.key] == "256")
        #expect(ensure["CMUX_APPS_FIRST_PARTY_DIR"] != nil)
    }

    /// A launch that raised nothing (a shell with a higher limit) names no launch limit.
    @Test func aLaunchThatRaisedNothingNamesNoLaunchLimit() {
        let environment = AppEnvironment.current([:], openFiles: .init(before: 50_000, after: 50_000))
        #expect(environment.launchOpenFileLimit == nil)
        #expect(environment.daemonEnvironment.isEmpty)
        #expect(DaemonService.ownerProcessEnvironment(launch: environment.daemonEnvironment)[Self.key] == nil)
    }
}
