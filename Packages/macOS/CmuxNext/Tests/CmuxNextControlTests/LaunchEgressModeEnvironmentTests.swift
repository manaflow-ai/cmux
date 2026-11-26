import CmuxNextControl
import CmuxNextDaemon
import Foundation
import Testing

/// A NIGHTLY or DEV launch's egress mode reaches its terminals over a remembered login environment
/// (docs/privacy.md, Egress gate). `TerminalEnvironment` takes `CMUX_*` keys from the login shell, so
/// before, a login environment's `CMUX_EGRESS=off` turned the gate off for every shell and the bundled
/// `cmux` CLI in the app's terminals.
struct LaunchEgressModeEnvironmentTests {
    static let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    static func launch(_ bundleID: String, _ process: [String: String] = [:]) -> LaunchIdentity {
        LaunchIdentity.resolve(bundleID: bundleID, bundledEnvironment: [:], processEnvironment: process,
                               isDebugBuild: false, home: home)
    }

    @Test func nightlyAndDevTerminalsEnforceOverALoginEnvironment() async {
        for bundle in ["com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.egress"] {
            let launch = Self.launch(bundle)
            #expect(launch.terminalEnvironment[LaunchIdentity.egressModeKey] == "enforce", "\(bundle)")
            let login = [LaunchIdentity.egressModeKey: "off"]
            let terminal = await TerminalEnvironment.instance.shared(base: [:], overrides: launch.terminalEnvironment,
                                                                     login: { login })()
            #expect(terminal[LaunchIdentity.egressModeKey] == "enforce", "\(bundle)")
            let daemon = TerminalEnvironment.instance.daemon(login: login, base: [:], overrides: launch.terminalEnvironment)
            #expect(daemon[LaunchIdentity.egressModeKey] == "enforce", "\(bundle)")
        }
    }

    @Test func theLaunchsOwnValueWins() {
        let launch = Self.launch("com.cmuxterm.app.nightly", [LaunchIdentity.egressModeKey: "log"])
        #expect(launch.terminalEnvironment[LaunchIdentity.egressModeKey] == "log")
    }

    @Test func releaseKeepsTheGatesDefault() {
        #expect(Self.launch("com.cmuxterm.app").terminalEnvironment[LaunchIdentity.egressModeKey] == nil)
    }
}
