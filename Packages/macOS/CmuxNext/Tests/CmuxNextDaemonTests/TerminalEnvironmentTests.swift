import Testing
@testable import CmuxNextDaemon

@Suite("Terminal environment")
struct TerminalEnvironmentTests {
    /// `echo $TERM_PROGRAM` in a cmux terminal says `cmux` (user, 2026-11-11).
    /// The daemon adds cmux's `TERM_PROGRAM_VERSION` at spawn, so the app's
    /// identity carries no version, least of all libghostty's.
    @Test
    func terminalIdentityIsCmuxWithoutAGhosttyVersion() {
        let environment = TerminalEnvironment.instance.ghostty(resourcesDirectory: nil, version: "1.2.0")

        #expect(environment["TERM_PROGRAM"] == "cmux")
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

@Suite("Terminal TERM choice")
struct TerminalTermChoiceTests {
    @Test
    func optInSelectsXtermGhosttyOnlyWhenItIsInstalled() {
        let environment = TerminalEnvironment.instance
        #expect(environment.term(prefersGhosttyTerm: true, home: "/home/u", fileExists: { $0 == "/home/u/.terminfo/78/xterm-ghostty" }) == "xterm-ghostty")
        #expect(environment.term(prefersGhosttyTerm: true, home: "/home/u", fileExists: { _ in false }) == "xterm-256color")
        #expect(environment.term(prefersGhosttyTerm: false, home: "/home/u", fileExists: { _ in true }) == "xterm-256color")
    }

    @Test
    func optInReachesTheGhosttyIdentity() {
        let environment = TerminalEnvironment.instance.ghostty(resourcesDirectory: nil, version: nil, prefersGhosttyTerm: true, fileExists: { _ in true })
        #expect(environment["TERM"] == "xterm-ghostty")
    }
}

@Suite("Terminal env provider TERM")
struct TerminalEnvironmentProviderTermTests {
    /// The per-terminal provider every local spawn uses ends with `xterm-256color`
    /// unless `terminal.term` opts in, whatever `TERM` the overrides carried.
    @Test
    func providerStartsTerminalsWithXterm256colorByDefault() async {
        let provider = TerminalEnvironment.instance.shared(base: [:], overrides: ["TERM": "xterm-ghostty"], login: { [:] })
        #expect(await provider()["TERM"] == "xterm-256color")
    }
}
