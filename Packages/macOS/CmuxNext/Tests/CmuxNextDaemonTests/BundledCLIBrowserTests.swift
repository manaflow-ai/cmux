@testable import CmuxNextDaemon
import Testing

/// A program in a cmux terminal that opens a browser (`aws login`, `gh auth login`, Python's
/// webbrowser) reaches cmux through `BROWSER`, which names the bundled `cmux-open-url`; a
/// `BROWSER` already set is the user's and is kept.
@Suite struct BundledCLIBrowserTests {
    let cli = BundledCLIEnvironment(binDirectory: "/A.app/Contents/Resources/bin", pathIntegration: nil)
    let executable: (String) -> Bool = { $0.hasPrefix("/A.app/Contents/Resources/bin/") }

    @Test func browserNamesTheBundledOpener() {
        let env = cli.apply(to: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"], isExecutable: executable)
        // The bare name: tools such as gh split BROWSER on spaces, and an app path may hold one.
        #expect(env["BROWSER"] == "cmux-open-url")
        #expect(env["PATH"] == "/A.app/Contents/Resources/bin:/usr/bin")
    }

    @Test func aBrowserTheUserSetWins() {
        let env = cli.apply(to: ["PATH": "/usr/bin", "BROWSER": "firefox"], isExecutable: executable)
        #expect(env["BROWSER"] == "firefox")
    }

    @Test func noOpenerInTheBundleLeavesBrowserUnset() {
        let env = cli.apply(to: ["PATH": "/usr/bin"], isExecutable: { $0.hasSuffix("/cmux") })
        #expect(env["BROWSER"] == nil)
    }
}
