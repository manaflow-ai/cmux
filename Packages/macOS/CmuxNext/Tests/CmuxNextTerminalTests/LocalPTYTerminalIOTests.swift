import Testing
@testable import CmuxNextTerminal

@Suite("Local PTY terminal environment")
struct LocalPTYTerminalIOTests {
    @Test
    func ghosttyIdentityDoesNotAdvertiseNativeSelectionVersion() {
        let environment = LocalPTYTerminalIO.terminalEnvironment(resourcesDirectory: nil, version: "1.2.0")

        #expect(environment["TERM_PROGRAM"] == "ghostty")
        #expect(environment["TERM_PROGRAM_VERSION"] == nil)
    }
}
