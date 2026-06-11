import Foundation
import Testing
import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> (String) -> Bool {
    { path in existingPaths.contains((path as NSString).standardizingPath) }
}

@Suite struct TerminalPathTrailingPunctuationTests {
    @Test func trimsTrailingPeriodAfterMarkdownFile() {
        #expect(
            TerminalPathResolver.trimTrailingPunctuation("~/ClaudeCode/feature-spec-template.md.")
                == "~/ClaudeCode/feature-spec-template.md"
        )
    }

    @Test func trimsTrailingCommaInList() {
        #expect(
            TerminalPathResolver.trimTrailingPunctuation("/tmp/fixtures/first.txt,")
                == "/tmp/fixtures/first.txt"
        )
    }

    @Test func trimsTrailingCloseParenWhenNoBalancedOpenParen() {
        #expect(
            TerminalPathResolver.trimTrailingPunctuation("/tmp/fixtures/notes.txt)")
                == "/tmp/fixtures/notes.txt"
        )
    }

    @Test func preservesBalancedParensInMiddleOfPath() {
        #expect(
            TerminalPathResolver.trimTrailingPunctuation("/tmp/fixtures/report (draft)/notes.txt")
                == "/tmp/fixtures/report (draft)/notes.txt"
        )
    }

    @Test func stripsMultipleTrailingPunctuationCharacters() {
        #expect(
            TerminalPathResolver.trimTrailingPunctuation("/tmp/fixtures/report (draft).md).,!?\"")
                == "/tmp/fixtures/report (draft).md"
        )
    }

    @Test func trimsTrailingClosingQuote() {
        #expect(
            TerminalPathResolver.trimTrailingPunctuation("/tmp/fixtures/notes.txt\"")
                == "/tmp/fixtures/notes.txt"
        )
    }
}

@Suite struct TerminalQuicklookPathResolutionTests {
    @Test func fallsBackToStrippedPathWhenLiteralPathIsMissing() {
        let strippedPath = "/tmp/cmux-cmdclick-path.md"
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                "\(strippedPath).",
                cwd: "/tmp",
                fileExists: existsIn([strippedPath])
            ) == strippedPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithDot() {
        let literalPath = "/tmp/cmux-cmdclick-literal-dot.md."
        let strippedPath = "/tmp/cmux-cmdclick-literal-dot.md"
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                literalPath,
                cwd: "/tmp",
                fileExists: existsIn([literalPath, strippedPath])
            ) == literalPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithParen() {
        let literalPath = "/tmp/cmux-cmdclick-literal-paren)"
        let strippedPath = "/tmp/cmux-cmdclick-literal-paren"
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                literalPath,
                cwd: "/tmp",
                fileExists: existsIn([literalPath, strippedPath])
            ) == literalPath
        )
    }

    @Test func resolvesRelativeMarkdownPathWithTrailingDot() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                "docs/specs/2026-05-22-test.md.",
                cwd: cwd,
                fileExists: existsIn([existingFile])
            ) == existingFile
        )
    }

    @Test func resolvesRelativePathWithTrailingComma() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/src/main.swift"
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                "src/main.swift,",
                cwd: cwd,
                fileExists: existsIn([existingFile])
            ) == existingFile
        )
    }

    @Test func returnsNilForRelativePathThatDoesNotExist() {
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                "docs/nonexistent.md.",
                cwd: "/Users/dev/project",
                fileExists: existsIn([])
            ) == nil
        )
    }

    @Test func relativeCandidateWithoutCwdIsSkipped() {
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                "src/main.swift",
                cwd: nil,
                fileExists: { _ in true }
            ) == nil
        )
    }

    @Test func unquotesShellQuotedToken() {
        let existingFile = "/tmp/cmux quicklook spaced.md"
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                "\"\(existingFile)\"",
                cwd: "/tmp",
                fileExists: existsIn([existingFile])
            ) == existingFile
        )
    }

    @Test func unescapesBackslashEscapedSpaces() {
        let existingFile = "/tmp/cmux quicklook escaped.md"
        #expect(
            TerminalPathResolver.resolveQuicklookPath(
                "/tmp/cmux\\ quicklook\\ escaped.md",
                cwd: "/tmp",
                fileExists: existsIn([existingFile])
            ) == existingFile
        )
    }
}

@Suite struct TerminalOpenURLFilePathTests {
    @Test func resolvesAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver.resolveOpenURLFilePath(
                "\(existingFile).",
                cwd: "/Users/dev/project",
                fileExists: existsIn([existingFile])
            ) == existingFile
        )
    }

    @Test func resolvesQuotedAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver.resolveOpenURLFilePath(
                "\"\(existingFile).\"",
                cwd: "/Users/dev/project",
                fileExists: existsIn([existingFile])
            ) == existingFile
        )
    }

    @Test func textWithURLSchemeIsNeverTreatedAsFilePath() {
        #expect(
            TerminalPathResolver.resolveOpenURLFilePath(
                "file:///tmp/test.md",
                cwd: "/tmp",
                fileExists: { _ in true }
            ) == nil
        )
        #expect(
            TerminalPathResolver.resolveOpenURLFilePath(
                "mailto:test@example.com",
                cwd: "/tmp",
                fileExists: { _ in true }
            ) == nil
        )
    }

    @Test func schemelessRelativeAndAbsoluteTextStaysEligible() {
        let relative = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver.resolveOpenURLFilePath(
                "docs/specs/2026-05-22-test.md.",
                cwd: "/Users/dev/project",
                fileExists: existsIn([relative])
            ) == relative
        )
    }
}

@Suite struct TerminalVisibleLineResolutionTests {
    @Test func visibleLinesKeepsTrailingRowsOnly() {
        let text = "one\ntwo\nthree\nfour"
        #expect(TerminalPathResolver.visibleLines(from: text, rows: 2) == ["three", "four"])
        #expect(TerminalPathResolver.visibleLines(from: text, rows: 10) == ["one", "two", "three", "four"])
    }

    @Test func visibleLinesPreservesEmptyLines() {
        #expect(TerminalPathResolver.visibleLines(from: "a\n\nb", rows: 3) == ["a", "", "b"])
    }

    @Test func resolvesRawSegmentUnderColumn() throws {
        let existingFile = "/tmp/cmux-visible-line.md"
        let line = "open /tmp/cmux-visible-line.md now"
        let resolution = try #require(
            TerminalPathResolver.resolveVisibleLinePath(
                line,
                column: 8,
                cwd: "/tmp",
                fileExists: existsIn([existingFile])
            )
        )
        #expect(resolution.path == existingFile)
        #expect(resolution.rawToken == "/tmp/cmux-visible-line.md")
    }

    @Test func resolvesShellEscapedTokenSpanningSpaces() throws {
        let existingFile = "/tmp/cmux visible escaped.md"
        let line = "cat /tmp/cmux\\ visible\\ escaped.md"
        let resolution = try #require(
            TerminalPathResolver.resolveVisibleLinePath(
                line,
                column: 6,
                cwd: "/tmp",
                fileExists: existsIn([existingFile])
            )
        )
        #expect(resolution.path == existingFile)
    }

    @Test func returnsNilWhenColumnSitsOnHardDelimiter() {
        #expect(
            TerminalPathResolver.resolveVisibleLinePath(
                "a\tb",
                column: 1,
                cwd: "/tmp",
                fileExists: { _ in true }
            ) == nil
        )
    }
}
