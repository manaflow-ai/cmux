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
}
