import Testing

@testable import CmuxAgentChat

@Suite("TerminalArtifactPathDetector")
struct TerminalArtifactPathDetectorTests {
    @Test("extracts absolute and relative path tokens with shell punctuation")
    func extractsPathTokens() {
        let text = """
        opened "/tmp/project/image.png", see ./notes/todo.md and ../logs/out.txt.
        ignored https://example.com/a/b plus word and duplicate /tmp/project/image.png
        OSC8-ish file:///tmp/project/report.txt
        """
        let paths = TerminalArtifactPathDetector().paths(in: text)
        #expect(paths == [
            "/tmp/project/image.png",
            "./notes/todo.md",
            "../logs/out.txt",
            "/tmp/project/report.txt",
        ])
    }
}
