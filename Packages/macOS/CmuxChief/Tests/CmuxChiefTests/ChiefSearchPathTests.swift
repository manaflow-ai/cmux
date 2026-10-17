@testable import CmuxChief
import Foundation
import Testing

/// The `PATH` a Chief turn runs with: an app opened from the Dock or Finder
/// gets launchd's minimal `PATH`, so tools the user runs in Terminal (`gh`,
/// Homebrew installs) must still be found by the brain's shell commands.
@Suite struct ChiefSearchPathTests {
    let home = "/Users/test"

    @Test func aMinimalAppPathGainsTheLoginShellPath() {
        let path = ChiefSearchPath.merged(base: "/usr/bin:/bin:/usr/sbin:/sbin",
                                          loginShell: "/opt/homebrew/bin:/usr/bin:/bin:/custom/tools",
                                          home: home)
        let entries = path.split(separator: ":").map(String.init)
        #expect(Array(entries.prefix(4)) == ["/opt/homebrew/bin", "/usr/bin", "/bin", "/custom/tools"])
        #expect(entries.contains("/usr/sbin"))
        #expect(entries.count == Set(entries).count)
    }

    @Test func withoutALoginShellTheUsualInstallPlacesAreStillSearched() {
        let path = ChiefSearchPath.merged(base: "/usr/bin:/bin:/usr/sbin:/sbin", loginShell: nil, home: home)
        let entries = path.split(separator: ":").map(String.init)
        #expect(Array(entries.prefix(4)) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        for directory in ["/Users/test/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            #expect(entries.contains(directory))
        }
    }

    @Test func theLoginShellReportIgnoresProfileChatter() {
        let output = "Welcome back!\n\(ChiefLoginShellPath.marker)/opt/homebrew/bin:/usr/bin\n"
        #expect(ChiefLoginShellPath.parse(output) == "/opt/homebrew/bin:/usr/bin")
        #expect(ChiefLoginShellPath.parse("no marker here") == nil)
        #expect(ChiefLoginShellPath.parse("\(ChiefLoginShellPath.marker)   ") == nil)
    }

    @Test func theLoginShellRunsOncePerApp() async {
        let runs = RunCounter()
        let lookup = ChiefLoginShellPath { await runs.next() }
        async let first = lookup.value()
        async let second = lookup.value()
        #expect(await first == "/opt/homebrew/bin:/usr/bin")
        #expect(await second == "/opt/homebrew/bin:/usr/bin")
        #expect(await lookup.value() == "/opt/homebrew/bin:/usr/bin")
        #expect(await runs.count == 1)
    }
}

private actor RunCounter {
    private(set) var count = 0

    func next() -> String? {
        count += 1
        return "/opt/homebrew/bin:/usr/bin"
    }
}
