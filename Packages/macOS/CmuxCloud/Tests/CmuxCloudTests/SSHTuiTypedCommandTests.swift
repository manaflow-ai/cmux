import CmuxCloud
import Testing

@Suite("Typed initial input on remote terminals")
struct SSHTuiTypedCommandTests {
    @Test("Only one line ended by Return becomes a remote command")
    func typedCommandParsing() {
        #expect(SSHTuiConnection.typedCommand(fromInitialInput: "echo hi\r") == "echo hi")
        #expect(SSHTuiConnection.typedCommand(fromInitialInput: "echo hi") == nil)
        #expect(SSHTuiConnection.typedCommand(fromInitialInput: "one\ntwo\r") == nil)
        #expect(SSHTuiConnection.typedCommand(fromInitialInput: "one\rtwo\r") == nil)
        #expect(SSHTuiConnection.typedCommand(fromInitialInput: "  \r") == nil)
        // Swift folds CRLF into one Character, so this line break must be found by scalar.
        #expect(SSHTuiConnection.typedCommand(fromInitialInput: "one\r\ntwo\r") == nil)
        #expect(SSHTuiConnection.typedCommand(fromInitialInput: "one\r\n") == nil)
    }

    @Test("The typed command runs in the login shell, then a login shell replaces it")
    func typedCommandArguments() {
        #expect(SSHTuiConnection.typedCommandArguments("echo hi") == [
            "/bin/sh", "-c", "trap : INT; \"${SHELL:-/bin/sh}\" -lc \"$1\"; trap - INT; exec \"${SHELL:-/bin/sh}\" -l", "cmux-ssh", "echo hi",
        ])
    }
}
