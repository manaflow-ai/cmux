import Testing
@testable import CmuxNextDaemon

@Suite("Terminal environment")
struct TerminalEnvironmentTests {
    @Test
    func ghosttyIdentityDoesNotAdvertiseNativeSelectionVersion() {
        let environment = TerminalEnvironment.instance.ghostty(resourcesDirectory: nil, version: "1.2.0")

        #expect(environment["TERM_PROGRAM"] == "ghostty")
        #expect(environment["TERM_PROGRAM_VERSION"] == nil)
    }

    /// `ssh ultra2 htop` from a cmux terminal failed with "cannot initialize
    /// terminal type xterm-ghostty" (user, 2026-11-05): an `xterm-ghostty`
    /// installed in `~/.terminfo` on this Mac must not leak to ssh hosts.
    @Test
    func defaultTermIsXterm256colorEvenWithGhosttyTerminfoInstalled() {
        let environment = TerminalEnvironment.instance.ghostty(resourcesDirectory: nil, version: nil, fileExists: { _ in true })

        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
    }
}
