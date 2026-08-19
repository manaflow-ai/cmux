import CMUXAgentLaunch
import Testing

@Suite("TerminalStartupShellDialect")
struct TerminalStartupShellDialectTests {
    @Test("Detects Nushell by executable basename")
    func detectsNushell() {
        #expect(TerminalStartupShellDialect.forShellPath("/opt/homebrew/bin/nu") == .nushell)
        #expect(TerminalStartupShellDialect.forShellPath("/usr/local/bin/nu") == .nushell)
        #expect(TerminalStartupShellDialect.forShellPath("/opt/homebrew/bin/nushell") == .posix)
    }

    @Test("Treats missing and POSIX shells as POSIX")
    func detectsPosixFallbacks() {
        #expect(TerminalStartupShellDialect.forShellPath("/bin/zsh") == .posix)
        #expect(TerminalStartupShellDialect.forShellPath(nil) == .posix)
        #expect(TerminalStartupShellDialect.forShellPath("") == .posix)
    }

    @Test("Resolves the login shell from an injected environment")
    func resolvesInjectedLoginShell() {
        #expect(TerminalStartupShellDialect.loginShell(environment: ["SHELL": "/bin/nu"]) == .nushell)
        #expect(TerminalStartupShellDialect.loginShell(environment: [:]) == .posix)
    }

    @Test("Keeps remote-host inputs in the historical POSIX dialect")
    func remoteHostIsPosix() {
        #expect(TerminalStartupShellDialect.remoteHost == .posix)
    }
}
