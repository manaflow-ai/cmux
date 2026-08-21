import Foundation
import Testing
import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> @Sendable (String) -> Bool {
    { path in existingPaths.contains((path as NSString).standardizingPath) }
}

@Suite struct TerminalPathTrailingPunctuationTests {
    @Test func trimsTrailingPeriodAfterMarkdownFile() {
        #expect(
            "~/ClaudeCode/feature-spec-template.md.".trimmingTrailingTerminalPunctuation()
                == "~/ClaudeCode/feature-spec-template.md"
        )
    }

    @Test func trimsTrailingCommaInList() {
        #expect(
            "/tmp/fixtures/first.txt,".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/first.txt"
        )
    }

    @Test func trimsTrailingCloseParenWhenNoBalancedOpenParen() {
        #expect(
            "/tmp/fixtures/notes.txt)".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }

    @Test func preservesBalancedParensInMiddleOfPath() {
        #expect(
            "/tmp/fixtures/report (draft)/notes.txt".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/report (draft)/notes.txt"
        )
    }

    @Test func stripsMultipleTrailingPunctuationCharacters() {
        #expect(
            "/tmp/fixtures/report (draft).md).,!?\"".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/report (draft).md"
        )
    }

    @Test func trimsTrailingClosingQuote() {
        #expect(
            "/tmp/fixtures/notes.txt\"".trimmingTrailingTerminalPunctuation()
                == "/tmp/fixtures/notes.txt"
        )
    }
}

@Suite struct TerminalQuicklookPathResolutionTests {
    @Test func fallsBackToStrippedPathWhenLiteralPathIsMissing() {
        let strippedPath = "/tmp/cmux-cmdclick-path.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([strippedPath])).resolveQuicklookPath(
                "\(strippedPath).",
                cwd: "/tmp"
            ) == strippedPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithDot() {
        let literalPath = "/tmp/cmux-cmdclick-literal-dot.md."
        let strippedPath = "/tmp/cmux-cmdclick-literal-dot.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithParen() {
        let literalPath = "/tmp/cmux-cmdclick-literal-paren)"
        let strippedPath = "/tmp/cmux-cmdclick-literal-paren"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func resolvesRelativeMarkdownPathWithTrailingDot() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "docs/specs/2026-05-22-test.md.",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func resolvesRelativePathWithTrailingComma() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/src/main.swift"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "src/main.swift,",
                cwd: cwd
            ) == existingFile
        )
    }

    @Test func returnsNilForRelativePathThatDoesNotExist() {
        #expect(
            TerminalPathResolver(fileExists: existsIn([])).resolveQuicklookPath(
                "docs/nonexistent.md.",
                cwd: "/Users/dev/project"
            ) == nil
        )
    }

    @Test func relativeCandidateWithoutCwdIsSkipped() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveQuicklookPath(
                "src/main.swift",
                cwd: nil
            ) == nil
        )
    }

    @Test func unquotesShellQuotedToken() {
        let existingFile = "/tmp/cmux quicklook spaced.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "\"\(existingFile)\"",
                cwd: "/tmp"
            ) == existingFile
        )
    }

    @Test func unescapesBackslashEscapedSpaces() {
        let existingFile = "/tmp/cmux quicklook escaped.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveQuicklookPath(
                "/tmp/cmux\\ quicklook\\ escaped.md",
                cwd: "/tmp"
            ) == existingFile
        )
    }
}

@Suite struct TerminalOpenURLFilePathTests {
    @Test func resolvesAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                "\(existingFile).",
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func resolvesQuotedAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                "\"\(existingFile).\"",
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func textWithURLSchemeIsNeverTreatedAsFilePath() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "file:///tmp/test.md",
                cwd: "/tmp"
            ) == nil
        )
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "mailto:test@example.com",
                cwd: "/tmp"
            ) == nil
        )
    }

    @Test func schemelessRelativeAndAbsoluteTextStaysEligible() {
        let relative = "/Users/dev/project/docs/specs/2026-05-22-test.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([relative])).resolveOpenURLFilePath(
                "docs/specs/2026-05-22-test.md.",
                cwd: "/Users/dev/project"
            ) == relative
        )
    }
}

@Suite struct TerminalVisibleLineResolutionTests {
    @Test func visibleLinesKeepsTrailingRowsOnly() {
        let text = "one\ntwo\nthree\nfour"
        #expect(text.visibleLines(rows: 2) == ["three", "four"])
        #expect(text.visibleLines(rows: 10) == ["one", "two", "three", "four"])
    }

    @Test func visibleLinesPreservesEmptyLines() {
        #expect("a\n\nb".visibleLines(rows: 3) == ["a", "", "b"])
    }

    @Test func resolvesRawSegmentUnderColumn() throws {
        let existingFile = "/tmp/cmux-visible-line.md"
        let line = "open /tmp/cmux-visible-line.md now"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: 8,
                cwd: "/tmp"
            )
        )
        #expect(resolution.path == existingFile)
        #expect(resolution.rawToken == "/tmp/cmux-visible-line.md")
    }

    @Test func resolvesShellEscapedTokenSpanningSpaces() throws {
        let existingFile = "/tmp/cmux visible escaped.md"
        let line = "cat /tmp/cmux\\ visible\\ escaped.md"
        let resolution = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLinePath(
                line,
                column: 6,
                cwd: "/tmp"
            )
        )
        #expect(resolution.path == existingFile)
    }

    @Test func returnsNilWhenColumnSitsOnHardDelimiter() {
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveVisibleLinePath(
                "a\tb",
                column: 1,
                cwd: "/tmp"
            ) == nil
        )
    }
}

@Suite struct TerminalPathLineSuffixTests {
    @Test func stripsLineNumber() {
        #expect("src/main.py:1292".strippingTrailingLineSuffix() == "src/main.py")
    }

    @Test func stripsLineRange() {
        #expect(
            "docs/synthetic-monitoring.md:144-198".strippingTrailingLineSuffix()
                == "docs/synthetic-monitoring.md"
        )
    }

    @Test func stripsLineAndColumn() {
        #expect("app/models/user.rb:12:5".strippingTrailingLineSuffix() == "app/models/user.rb")
    }

    @Test func stripsFromAbsolutePath() {
        #expect("/tmp/fixtures/notes.md:7".strippingTrailingLineSuffix() == "/tmp/fixtures/notes.md")
    }

    @Test func ignoresPathWithoutLineSuffix() {
        #expect("docs/synthetic-monitoring.md".strippingTrailingLineSuffix() == nil)
    }

    @Test func ignoresNonNumericFinalSegment() {
        #expect("/tmp/fixtures/notes.md:draft".strippingTrailingLineSuffix() == nil)
    }

    @Test func ignoresTrailingColonWithoutDigits() {
        #expect("/tmp/fixtures/notes.md:".strippingTrailingLineSuffix() == nil)
    }

    @Test func ignoresDigitsWithoutColon() {
        #expect("/tmp/fixtures/chapter2".strippingTrailingLineSuffix() == nil)
    }

    @Test func ignoresBareLineReferenceWithNoPath() {
        #expect(":144".strippingTrailingLineSuffix() == nil)
    }

    @Test func stripsAtMostTwoSegments() {
        // `:8` and `:16` come off; `:4` is left so genuine path components with
        // numeric names are not eaten wholesale.
        #expect("/tmp/a:4:8:16".strippingTrailingLineSuffix() == "/tmp/a:4")
    }
}

@Suite struct TerminalQuicklookLineSuffixResolutionTests {
    @Test func resolvesRelativePathWithLineNumber() {
        let path = "/tmp/cmux-linesuffix/src/main.py"
        #expect(
            TerminalPathResolver(fileExists: existsIn([path])).resolveQuicklookPath(
                "src/main.py:1292",
                cwd: "/tmp/cmux-linesuffix"
            ) == path
        )
    }

    @Test func resolvesRelativePathWithLineRange() {
        let path = "/tmp/cmux-linesuffix/docs/notes.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([path])).resolveQuicklookPath(
                "docs/notes.md:144-198",
                cwd: "/tmp/cmux-linesuffix"
            ) == path
        )
    }

    @Test func resolvesAbsolutePathWithLineAndColumn() {
        let path = "/tmp/cmux-linesuffix/app/user.rb"
        #expect(
            TerminalPathResolver(fileExists: existsIn([path])).resolveQuicklookPath(
                "\(path):12:5",
                cwd: "/tmp"
            ) == path
        )
    }

    @Test func resolvesLineSuffixFollowedByTrailingPunctuation() {
        let path = "/tmp/cmux-linesuffix/docs/notes.md"
        #expect(
            TerminalPathResolver(fileExists: existsIn([path])).resolveQuicklookPath(
                "\(path):144).",
                cwd: "/tmp"
            ) == path
        )
    }

    @Test func prefersLiteralPathThatReallyEndsWithLineSuffix() {
        let literalPath = "/tmp/cmux-linesuffix/backup:2024"
        let strippedPath = "/tmp/cmux-linesuffix/backup"
        #expect(
            TerminalPathResolver(fileExists: existsIn([literalPath, strippedPath])).resolveQuicklookPath(
                literalPath,
                cwd: "/tmp"
            ) == literalPath
        )
    }

    @Test func stillReturnsNilWhenNeitherSpellingExists() {
        #expect(
            TerminalPathResolver(fileExists: existsIn([])).resolveQuicklookPath(
                "src/missing.py:10",
                cwd: "/tmp/cmux-linesuffix"
            ) == nil
        )
    }
}

@Suite struct TerminalOpenURLLineSuffixTests {
    @Test func openURLResolvesPathWithLineNumber() {
        let path = "/tmp/cmux-linesuffix/src/main.py"
        #expect(
            TerminalPathResolver(fileExists: existsIn([path])).resolveOpenURLFilePath(
                "src/main.py:1292",
                cwd: "/tmp/cmux-linesuffix"
            ) == path
        )
    }
}
