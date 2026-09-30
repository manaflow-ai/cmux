@testable import CmuxNextApp
import Testing

/// Coordinator decision 2026-09-30: closing an incognito window (or
/// quitting with one open) asks first when a terminal in it runs a program
/// other than the shell, the rule Close Workspace uses; otherwise it closes
/// at once.
struct IncognitoCloseConfirmationTests {
    @Test func idleTerminalsCloseWithoutAsking() {
        #expect(IncognitoCloseConfirmation.prompt(programs: [], quitting: false) == nil)
        #expect(IncognitoCloseConfirmation.prompt(programs: [], quitting: true) == nil)
    }

    @Test func runningProgramsAsk() throws {
        let close = try #require(IncognitoCloseConfirmation.prompt(programs: ["npm", "vim"], quitting: false))
        #expect(close.body.contains("npm, vim"))
        #expect(close.button == ConfirmationStrings.close)
        let quit = try #require(IncognitoCloseConfirmation.prompt(programs: ["vim"], quitting: true))
        #expect(quit.body.contains("vim"))
        #expect(quit.title != close.title)
    }
}
