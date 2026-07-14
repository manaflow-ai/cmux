import Testing

@testable import CmuxAgentChat

@Suite("TerminalArtifactPathDetector")
struct TerminalArtifactPathDetectorTests {
    @Test("extracts absolute and relative path tokens with shell punctuation")
    func extractsPathTokens() {
        let text = """
        opened "/tmp/project/image.png", see ./notes/todo.md and ../logs/out.txt.
        ignored https://example.com/a/b plus word and duplicate /tmp/project/image.png
        wrote ./single.md too
        OSC8-ish file:///tmp/project/report.txt
        """
        let paths = TerminalArtifactPathDetector().paths(in: text)
        #expect(paths == [
            "/tmp/project/image.png",
            "./notes/todo.md",
            "../logs/out.txt",
            "./single.md",
            "/tmp/project/report.txt",
        ])
    }

    @Test("T9 extracts absolute markdown-link destinations")
    func markdownLinkDestination() {
        let paths = TerminalArtifactPathDetector().paths(
            in: "Open [report](/tmp/parity/T9-markdown.html) next."
        )
        #expect(paths == ["/tmp/parity/T9-markdown.html"])
    }

    @Test("T3 extracts a path after parenthesis wrapper trimming")
    func parenthesizedPath() {
        let paths = TerminalArtifactPathDetector().paths(
            in: "Open (/Users/test/project/T3-parent.md)."
        )
        #expect(paths == ["/Users/test/project/T3-parent.md"])
    }

    @Test(
        "rejects owner-ruled non-artifact path shapes",
        arguments: [
            "/",
            #"/").deletingLastPathComponent().path"#,
            "/Users/x/<agent>-hook-sessions.json",
        ]
    )
    func rejectsNonArtifactPathShapes(_ candidate: String) {
        #expect(TerminalArtifactPathDetector().paths(in: candidate).isEmpty)
    }

    @Test("O4 strips grep line and column suffixes")
    func grepLineAndColumnSuffix() {
        let paths = TerminalArtifactPathDetector().paths(
            in: "/tmp/parity/O4-line.swift:12:34:func and /tmp/parity/O4-line-only.swift:9:"
        )
        #expect(paths == [
            "/tmp/parity/O4-line.swift",
            "/tmp/parity/O4-line-only.swift",
        ])
    }
}
