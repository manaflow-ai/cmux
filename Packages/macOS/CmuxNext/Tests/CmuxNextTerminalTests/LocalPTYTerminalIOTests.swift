import Testing
@testable import CmuxNextTerminal

@Suite("Local PTY terminal environment")
struct LocalPTYTerminalIOTests {
    @Test
    func inheritedGhosttyVersionDoesNotReachTheLocalPTY() {
        let environment = LocalPTYTerminalIO.childEnvironment(
            inherited: ["TERM_PROGRAM_VERSION": "1.3.2"],
            extra: [:]
        )

        #expect(environment["TERM_PROGRAM_VERSION"] == nil)
    }

    @Test
    func ghosttyIdentityDoesNotAdvertiseNativeSelectionVersion() {
        let environment = LocalPTYTerminalIO.terminalEnvironment(resourcesDirectory: nil, version: "1.2.0")

        #expect(environment["TERM_PROGRAM"] == "ghostty")
        #expect(environment["TERM_PROGRAM_VERSION"] == nil)
    }
}
