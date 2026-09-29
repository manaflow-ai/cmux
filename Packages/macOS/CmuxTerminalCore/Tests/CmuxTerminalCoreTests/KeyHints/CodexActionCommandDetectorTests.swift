import Testing
@testable import CmuxTerminalCore

struct CodexActionCommandDetectorTests {
    @Test func recognizesOnlyCompleteGoalResumeRow() {
        let detector = CodexActionCommandDetector()
        #expect(detector.command(in: "  /goal resume  ", atColumn: 3)?.command == "/goal resume")
        #expect(detector.command(in: "echo /goal resume", atColumn: 6) == nil)
        #expect(detector.command(in: "/goal resume now", atColumn: 3) == nil)
    }
}
