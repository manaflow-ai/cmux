import Testing
@testable import CmuxTerminalCore

struct AgentActionCommandDetectorTests {
    @Test func recognizesOnlyAllowlistedCodexCommand() {
        let detector = CodexActionCommandDetector()
        let command = detector.command(in: "  /goal resume  ", atColumn: 3)
        #expect(command?.command == "/goal resume")
        #expect(command?.columns == 2..<14)
    }

    @Test func rejectsShellTextAndPartialCommands() {
        let detector = CodexActionCommandDetector()
        #expect(detector.commands(in: "echo /goal resume").isEmpty)
        #expect(detector.commands(in: "/goal reset").isEmpty)
        #expect(detector.command(in: "/goal resume now", atColumn: 3) != nil)
    }
}
