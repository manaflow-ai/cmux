@testable import CmuxNextApps
import Testing

/// The error card of a section whose script does not load shows the message and the line apart.
@Suite struct AppScriptFailureTests {
    @Test func aSyntaxErrorSplitsIntoTheMessageAndItsLine() {
        let failure = AppScriptFailure(reason: "init: main: Error: expecting ';' at main.js:2:12")
        #expect(failure.message == "expecting ';'")
        #expect(failure.location == "main.js:2:12")
    }

    @Test func anOlderHostsUnnamedScriptKeepsItsLocation() {
        let failure = AppScriptFailure(reason: "init: main: Error: expecting ';' at eval_script:2:12")
        #expect(failure.message == "expecting ';'")
        #expect(failure.location == "eval_script:2:12")
    }

    @Test func aStackFramesLocationIsFound() {
        let failure = AppScriptFailure(reason: "init: TypeError: not a function\n    at renderRecent (main.js:45:9)")
        #expect(failure.message == "TypeError: not a function\n    at renderRecent")
        #expect(failure.location == "main.js:45:9")
    }

    @Test(arguments: ["no such app", "removed", "the app is disabled"])
    func aReasonWithNoLocationStaysWhole(reason: String) {
        let failure = AppScriptFailure(reason: reason)
        #expect(failure.message == reason)
        #expect(failure.location == nil)
    }
}
