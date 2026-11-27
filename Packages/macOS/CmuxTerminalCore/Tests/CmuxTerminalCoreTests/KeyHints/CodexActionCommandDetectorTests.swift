import Testing
@testable import CmuxTerminalCore

struct CodexActionCommandDetectorTests {
    @Test(arguments: ["Goal paused", "Goal stalled", "Goal hit usage limits"])
    func recognizesGoalResumeFooter(status: String) {
        let detector = CodexActionCommandDetector()
        let line = "  \(status) (/goal resume)  "
        let start = 2 + status.count + 2
        let end = start + "/goal resume".count
        for column in start..<end {
            #expect(detector.command(in: line, atColumn: column) == CodexActionCommand(
                command: "/goal resume",
                columns: start..<end
            ))
        }
        #expect(detector.command(in: line, atColumn: start - 1) == nil)
        #expect(detector.command(in: line, atColumn: end) == nil)
        #expect(detector.command(in: line, atColumn: 2) == nil)
    }

    @Test(arguments: [
        "  /goal resume  ",
        "echo /goal resume",
        "/goal resume now",
        "echo Goal stalled (/goal resume)",
        "Goal stalled (/goal resume) extra",
        "Goal running (/goal resume)",
        "Goal stalled (/goal resume now)"
    ])
    func rejectsUnrecognizedRows(line: String) {
        let detector = CodexActionCommandDetector()
        for column in 0..<line.count {
            #expect(detector.command(in: line, atColumn: column) == nil)
        }
    }
}
