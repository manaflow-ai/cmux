#if DEBUG
@testable import CmuxNextCompat
@testable import CmuxNextTerminal
import Testing

/// A local shell's terminal identity is built with no file read, so a shell can be spawned from the main
/// thread: it checked 14 terminfo paths through `FileManager.checked` on the caller's
/// thread. The table is the test's own, so a check on the main thread shows as a site.
@MainActor @Suite
struct LocalPTYTerminalEnvironmentTests {
    @Test func theShellsIdentityIsBuiltOnTheMainThreadWithNoFileCheck() async {
        let table = BlockingViolationTable(mode: .record)
        let env = BlockingViolationTable.$scoped.withValue(table) {
            LocalPTYTerminalIO.terminalEnvironment(resourcesDirectory: "/Applications/cmux.app/Contents/Resources/ghostty",
                                                   version: "1.0")
        }
        await table.flush()

        #expect(table.sites.isEmpty, "the identity checked the disk on the main thread: \(table.sites)")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["TERM_PROGRAM_VERSION"] == "1.0")
        #expect(env["TERMINFO"] == nil)
    }

    @Test func aTerminfoTheCallerFoundSelectsGhosttysTerm() {
        let env = LocalPTYTerminalIO.terminalEnvironment(resourcesDirectory: nil, version: nil, installedTerminfo: true)
        #expect(env["TERM"] == "xterm-ghostty")
        #expect(env["GHOSTTY_RESOURCES_DIR"] == nil)
    }
}
#endif
