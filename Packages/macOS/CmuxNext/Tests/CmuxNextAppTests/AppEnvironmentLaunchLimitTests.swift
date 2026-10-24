@testable import CmuxNextApp
import CmuxNextCompat
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
}
