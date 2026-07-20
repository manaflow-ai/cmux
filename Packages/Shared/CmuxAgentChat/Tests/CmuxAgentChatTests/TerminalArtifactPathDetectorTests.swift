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

    @Test("extracts a first-line path after a captured OSC color-report prologue")
    func capturedOSCColorReportPrologue() {
        let text = "\u{1B}]10;rgb:ff/ff/ff\u{1B}\\\u{1B}]11;rgb:1e/1e/1e\u{1B}\\/tmp/dirtap-demo\n\n\u{1B}[0m\u{1B}[38;2;0;135;175m\u{1B}[48;2;88;88;88m \u{1B}[0m..."

        #expect(TerminalArtifactPathDetector().paths(in: text).contains("/tmp/dirtap-demo"))
    }

    @Test("extracts a path wrapped in SGR sequences")
    func sgrWrappedPath() {
        let text = "\u{1B}[1m/tmp/x/y.txt\u{1B}[0m"

        #expect(TerminalArtifactPathDetector().paths(in: text) == ["/tmp/x/y.txt"])
    }

    @Test("extracts a path glued to a BEL-terminated OSC sequence")
    func belTerminatedOSCBeforePath() {
        let text = "\u{1B}]0;terminal title\u{07}/tmp/osc-bel/file.txt"

        #expect(TerminalArtifactPathDetector().paths(in: text) == ["/tmp/osc-bel/file.txt"])
    }

    @Test("drops an unterminated trailing CSI sequence")
    func unterminatedTrailingCSI() {
        let text = "/tmp/complete/file.txt\u{1B}[38;2"

        #expect(TerminalArtifactPathDetector().paths(in: text) == ["/tmp/complete/file.txt"])
    }

    @Test("plain terminal text behavior is unchanged")
    func plainTextBehavior() {
        let text = "opened /tmp/plain/file.txt and ./relative/note.md; ignored words"

        #expect(TerminalArtifactPathDetector().paths(in: text) == [
            "/tmp/plain/file.txt",
            "./relative/note.md",
        ])
    }
}
