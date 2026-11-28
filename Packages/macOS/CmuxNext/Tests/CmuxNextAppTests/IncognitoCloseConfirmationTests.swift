@testable import CmuxNextApp
import Testing

/// Coordinator decision 2026-09-30: closing an incognito window asks first
/// when a terminal in it runs a program other than the shell, the rule
/// Close Workspace uses; otherwise it closes at once. Quitting asks in the
/// quit sheet (QuitPolicyTests).
struct IncognitoCloseConfirmationTests {
    @Test func idleTerminalsCloseWithoutAsking() {
        #expect(IncognitoCloseConfirmation.prompt(programs: []) == nil)
    }

    @Test func runningProgramsAsk() throws {
        let close = try #require(IncognitoCloseConfirmation.prompt(programs: ["npm", "vim"]))
        #expect(close.body.contains("npm, vim"))
        #expect(close.button == ConfirmationStrings.close)
    }
}
