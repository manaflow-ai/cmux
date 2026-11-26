import Testing
@testable import CmuxNextDaemon

@Suite("Terminal environment")
struct TerminalEnvironmentTests {
    /// A side instance's daemon (`side-instance.sh make`) ran without the app's
    /// `CMUX_NEXT_CONFIG_FILE` and read the Mac's shared settings and keybindings. The app's own
    /// daemon gets it; a terminal's env and a remote daemon's identity keys do not.
    @Test
    func daemonGetsTheAppSettingsFileButTerminalsDoNot() {
        let base = ["HOME": "/h", "PATH": "/usr/bin", "CMUX_NEXT_CONFIG_FILE": "/side/config/cmux-next.json"]
        let login = ["PATH": "/usr/bin", "LANG": "en_US.UTF-8"]
        let daemon = TerminalEnvironment.instance.daemon(login: login, base: base, overrides: [:])
        #expect(daemon["CMUX_NEXT_CONFIG_FILE"] == "/side/config/cmux-next.json")
        #expect(TerminalEnvironment.instance.terminal(login: login, base: base)["CMUX_NEXT_CONFIG_FILE"] == nil)
        #expect(!TerminalEnvironment.instance.daemonIdentityKeys.contains("CMUX_NEXT_CONFIG_FILE"))
        let unset = TerminalEnvironment.instance.daemon(login: login, base: ["HOME": "/h", "CMUX_NEXT_CONFIG_FILE": ""],
                                                         overrides: [:])
        #expect(unset["CMUX_NEXT_CONFIG_FILE"] == nil)
    }

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
