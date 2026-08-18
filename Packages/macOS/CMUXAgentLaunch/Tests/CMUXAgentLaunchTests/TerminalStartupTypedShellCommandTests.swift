import CMUXAgentLaunch
import Testing

@Suite("TerminalStartupTypedShellCommand")
struct TerminalStartupTypedShellCommandTests {
    @Test("Leaves POSIX commands unchanged")
    func preservesPosixCommand() {
        let command = "cd -- '/tmp/project' && 'claude' '--resume' 'SID'"
        #expect(
            TerminalStartupTypedShellCommand(dialect: .posix)
                .typedInput(posixCommand: command) == command
        )
    }

    @Test("Wraps POSIX commands for Nushell")
    func wrapsNushellCommand() {
        let command = "cd -- '/tmp/project' && 'claude' '--resume' 'SID'"
        #expect(
            TerminalStartupTypedShellCommand(dialect: .nushell)
                .typedInput(posixCommand: command)
                == #"^/bin/sh -c "cd -- '/tmp/project' && 'claude' '--resume' 'SID'""#
        )
    }
}
