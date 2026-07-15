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
    @Test(arguments: [
        ("./scripts/reload.sh", "/Users/dev/project/scripts/reload.sh"),
        ("../Shared/Package.swift", "/Users/dev/Shared/Package.swift"),
        ("Sources/App/SettingsWindowFactory.swift", "/Users/dev/project/Sources/App/SettingsWindowFactory.swift"),
        ("a/b/c", "/Users/dev/project/a/b/c"),
    ])
    func resolvesRelativePathForms(rawPath: String, existingFile: String) {
        #expect(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveOpenURLFilePath(
                rawPath,
                cwd: "/Users/dev/project"
            ) == existingFile
        )
    }

    @Test func resolvesRelativePathWithLineSuffix() {
        let existingFile = "/Users/dev/project/Sources/App/SettingsWindowFactory.swift"
        let resolution = TerminalPathResolver(fileExists: existsIn([existingFile]))
            .resolveOpenURLFileReference(
                "Sources/App/SettingsWindowFactory.swift:12",
                context: TerminalPathResolutionContext(workingDirectory: "/Users/dev/project")
            )
        #expect(resolution?.path == existingFile)
        #expect(resolution?.line == 12)
        #expect(resolution?.column == nil)
    }

    @Test func resolvesRelativePathWithLineAndColumnSuffix() {
        let existingFile = "/Users/dev/project/Sources/App/SettingsWindowFactory.swift"
        let resolution = TerminalPathResolver(fileExists: existsIn([existingFile]))
            .resolveOpenURLFileReference(
                "Sources/App/SettingsWindowFactory.swift:12:7",
                context: TerminalPathResolutionContext(workingDirectory: "/Users/dev/project")
            )
        #expect(resolution?.path == existingFile)
        #expect(resolution?.line == 12)
        #expect(resolution?.column == 7)
    }

    @Test func resolvesLocationSuffixBeforeTrailingProsePunctuation() {
        let existingFile = "/Users/dev/project/Settings.swift"
        let resolution = TerminalPathResolver(fileExists: existsIn([existingFile]))
            .resolveOpenURLFileReference(
                "Settings.swift:12,",
                context: TerminalPathResolutionContext(workingDirectory: "/Users/dev/project")
            )
        #expect(resolution?.path == existingFile)
        #expect(resolution?.line == 12)
    }

    @Test func locationSuffixDoesNotBypassExistenceCheck() {
        #expect(
            TerminalPathResolver(fileExists: existsIn([])).resolveOpenURLFilePath(
                "Sources/App/Missing.swift:12:7",
                cwd: "/Users/dev/project"
            ) == nil
        )
    }

    @Test func cwdWinsBeforeFallbackRoots() {
        let cwdFile = "/Users/dev/project/Sources/Settings.swift"
        let repositoryFile = "/Users/dev/project/Settings.swift"
        let resolution = TerminalPathResolver(fileExists: existsIn([cwdFile, repositoryFile]))
            .resolveOpenURLFileReference(
                "Settings.swift:8",
                context: TerminalPathResolutionContext(
                    workingDirectory: "/Users/dev/project/Sources",
                    fallbackDirectories: ["/Users/dev/project"]
                )
            )
        #expect(resolution?.path == cwdFile)
        #expect(resolution?.line == 8)
    }

    @Test func repositoryRootFallbackHandlesCwdChanges() {
        let repositoryFile = "/Users/dev/project/Sources/App/SettingsWindowFactory.swift"
        let resolution = TerminalPathResolver(fileExists: existsIn([repositoryFile]))
            .resolveOpenURLFileReference(
                "Sources/App/SettingsWindowFactory.swift:12:7",
                context: TerminalPathResolutionContext(
                    workingDirectory: "/Users/dev/project/Sources",
                    fallbackDirectories: ["/Users/dev/project", "/Users/dev"]
                )
            )
        #expect(resolution?.path == repositoryFile)
        #expect(resolution?.line == 12)
        #expect(resolution?.column == 7)
    }

    @Test func workspaceRootIsTriedAfterMissingRepositoryCandidate() {
        let workspaceFile = "/Users/dev/workspace/Sources/App.swift"
        let resolution = TerminalPathResolver(fileExists: existsIn([workspaceFile]))
            .resolveOpenURLFileReference(
                "Sources/App.swift:4",
                context: TerminalPathResolutionContext(
                    workingDirectory: "/Users/dev/workspace/build",
                    fallbackDirectories: ["/Users/dev/repository", "/Users/dev/workspace"]
                )
            )
        #expect(resolution?.path == workspaceFile)
        #expect(resolution?.line == 4)
    }

    @Test func literalFileEndingInNumericSuffixWins() {
        let literalFile = "/Users/dev/project/report.txt:12"
        let strippedFile = "/Users/dev/project/report.txt"
        let resolution = TerminalPathResolver(fileExists: existsIn([literalFile, strippedFile]))
            .resolveOpenURLFileReference(
                "report.txt:12",
                context: TerminalPathResolutionContext(workingDirectory: "/Users/dev/project")
            )
        #expect(resolution?.path == literalFile)
        #expect(resolution?.line == nil)
    }

    @Test func zeroLocationSuffixIsNotGuessed() {
        let strippedFile = "/Users/dev/project/report.txt"
        #expect(
            TerminalPathResolver(fileExists: existsIn([strippedFile]))
                .resolveOpenURLFileReference(
                    "report.txt:0",
                    context: TerminalPathResolutionContext(workingDirectory: "/Users/dev/project")
                ) == nil
        )
    }

    @Test(arguments: [
        "./scripts/reload.sh",
        "../Sources/App.swift:4",
        "Sources/App/SettingsWindowFactory.swift:12:7",
        "a/b/c",
        "s/pipeline-failure-state-model.md",
        "File.swift:12",
    ])
    func recognizesUnambiguousRelativePathReferences(rawText: String) {
        #expect(TerminalPathResolver().isRelativePathReferenceCandidate(rawText))
    }

    @Test func consumesOnlyUnresolvedRelativeOpenURLReferences() {
        let resolver = TerminalPathResolver()
        let resolved = TerminalPathResolution(
            path: "/Users/dev/project/Sources/App.swift",
            line: 12,
            column: 7
        )

        #expect(
            resolver.shouldConsumeUnresolvedOpenURLPathReference(
                "Sources/App.swift:12:7",
                resolvedReference: nil
            )
        )
        #expect(
            !resolver.shouldConsumeUnresolvedOpenURLPathReference(
                "Sources/App.swift:12:7",
                resolvedReference: resolved
            )
        )
    }

    @Test(arguments: [
        "https://example.com/path",
        "mailto:test@example.com",
        "example.com/docs",
        "localhost:3000/docs",
        "/tmp/App.swift:12",
        "foo_bar",
    ])
    func doesNotClassifyURLsAbsolutePathsOrOpaqueTokensAsRelativePaths(rawText: String) {
        #expect(!TerminalPathResolver().isRelativePathReferenceCandidate(rawText))
    }

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
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "https://example.com:443",
                cwd: "/tmp"
            ) == nil
        )
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolveOpenURLFilePath(
                "ssh:host/path:22",
                cwd: "/tmp"
            ) == nil
        )
        #expect(
            TerminalPathResolver(fileExists: { _ in true }).resolvePath(
                "\"https://example.com/path\"",
                context: TerminalPathResolutionContext(workingDirectory: "/tmp")
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

    @Test func visibleLinePreservesSourceLocation() throws {
        let existingFile = "/tmp/Sources/App.swift"
        let result = try #require(
            TerminalPathResolver(fileExists: existsIn([existingFile])).resolveVisibleLineReference(
                "error: Sources/App.swift:19:3",
                column: 12,
                context: TerminalPathResolutionContext(workingDirectory: "/tmp")
            )
        )
        #expect(result.resolution.path == existingFile)
        #expect(result.resolution.line == 19)
        #expect(result.resolution.column == 3)
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
