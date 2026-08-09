import Foundation
import Testing
import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> @Sendable (String) -> Bool {
    // Standardize the fixture set itself too, not just the incoming probe
    // path — `NSString.standardizingPath` strips a trailing `/`
    // (`"/a/b/".standardizingPath == "/a/b"`), so a directory fixture
    // written with its natural trailing slash (as terminal-visible
    // wrapped-path text always has one) would otherwise never match what
    // `TerminalPathResolver.probeExists` actually looks up.
    let standardized = Set(existingPaths.map { ($0 as NSString).standardizingPath })
    return { path in standardized.contains((path as NSString).standardizingPath) }
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

@Suite struct TerminalWrappedPathResolutionTests {
    // Exact repro from issue #8810: a hard wrap splits mid-word (no
    // punctuation before the break), e.g. `/…/TMLlaborator` on one row and
    // `y` alone on the next.
    @Test func resolvesExactReproAcrossHardWrap() throws {
        let existingFile = "/Users/dev/project/TMLlaborator" + "y"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let clickedRow = "/Users/dev/project/TMLlaborator"

        let seed = try #require(
            resolver.wrappedPathSeed(in: clickedRow, column: clickedRow.count - 1, cwd: "/tmp")
        )
        #expect(seed.directions == [.next])

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: "y", cwd: "/tmp")
        )
        #expect(candidate.path == existingFile)

        // (B) ExternalHover — the clicked token spans the whole clicked
        // row (no internal delimiter), and the winning `.next` fragment
        // ("y") is at row offset +1, both at absolute columns matching the
        // real text — never off by one, the exact failure mode a wrong
        // topRow/clickedRow conflation would produce.
        #expect(candidate.cellSpans == [
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 0, startColumn: 0, endColumn: clickedRow.count),
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 1, startColumn: 0, endColumn: 1),
        ])
    }

    @Test func previousDirectionJoinsTrailingFragmentOfRowAbove() throws {
        let existingFile = "/Users/dev/project/very-long-directory-name/file.txt"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        // The previous row wrapped, leaving the tail of the path (no
        // leading `/`) at the start of the clicked row. The clicked row is
        // a single bare-relative token touching both boundaries (nothing
        // before or after it), so the seed is ambiguous; only supplying
        // `previousRow` exercises the `.previous` derivation alone.
        let clickedRow = "file.txt"
        let previousRow = "/Users/dev/project/very-long-directory-name/"

        let seed = try #require(
            resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: "/tmp")
        )
        #expect(seed.directions == [.previous, .next])

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: "/tmp")
        )
        #expect(candidate.path == existingFile)

        // (B) ExternalHover — the winning `.previous` fragment is at row
        // offset -1 (the row ABOVE the clicked row) — this is exactly the
        // direction review Blocking 6 flagged as at risk of a 1-row
        // conflation with `topRow`/the snapshot scope's own origin.
        #expect(candidate.cellSpans == [
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 0, startColumn: 0, endColumn: clickedRow.count),
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: -1, startColumn: 0, endColumn: previousRow.count),
        ])
    }

    @Test func rowLocalResolutionTakesPriorityOverWrapDetection() {
        let existingFile = "/tmp/cmux-wrap-row-local.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        #expect(
            resolver.wrappedPathSeed(
                in: existingFile,
                column: 2,
                cwd: "/tmp"
            ) == nil
        )
    }

    @Test func bareRelativeTokenTouchingNeitherBoundaryReturnsNil() {
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        // Tabs hard-delimit "bar" from both "foo" before it and "baz"
        // after it, so neither the leading nor the trailing boundary is
        // touched (a bare-relative token touching only one boundary now
        // gets that single direction; touching neither still returns nil).
        let clickedRow = "foo\tbar\tbaz"
        #expect(
            resolver.wrappedPathSeed(in: clickedRow, column: 4, cwd: "/tmp") == nil
        )
    }

    @Test func slashPrefixedTokenWithoutTrailingBoundaryReturnsNil() {
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        // A tab hard-delimits "/subdir" from "extra", but "extra" isn't
        // whitespace, so the trailing boundary isn't touched.
        let clickedRow = "/subdir\textra"
        #expect(
            resolver.wrappedPathSeed(in: clickedRow, column: 1, cwd: "/tmp") == nil
        )
    }

    @Test func nonASCIIRowFailsClosed() {
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        let clickedRow = "/Users/dev/caf\u{e9}proj"
        #expect(
            resolver.wrappedPathSeed(in: clickedRow, column: 5, cwd: "/tmp") == nil
        )
    }

    @Test func coincidentalAdjacentFragmentThatAloneExistsIsRejected() {
        let joinedFile = "/Users/dev/project/TMLlaboratory"
        let fragmentAloneFile = "/tmp/y"
        let resolver = TerminalPathResolver(fileExists: existsIn([joinedFile, fragmentAloneFile]))
        let clickedRow = "/Users/dev/project/TMLlaborator"

        guard let seed = resolver.wrappedPathSeed(
            in: clickedRow,
            column: clickedRow.count - 1,
            cwd: "/tmp"
        ) else {
            Issue.record("Expected a seed for the clicked row")
            return
        }

        #expect(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: "y", cwd: "/tmp") == nil
        )
    }

    @Test func candidateNotStartingWithSlashIsRejected() {
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        let clickedRow = "notAbsolute"
        // Not `/`-prefixed and touches both boundaries (nothing before or
        // after this single-token row), so the seed is ambiguous; supplying
        // only `previousRow` exercises the `.previous` derivation, whose
        // joined candidate still won't start with `/` since neither
        // fragment does.
        let seed = resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: "/tmp")
        guard let seed else {
            Issue.record("Expected a seed for the non-slash token")
            return
        }
        #expect(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: "prefix", nextRow: nil, cwd: "/tmp") == nil
        )
    }

    @Test func continuationIndentationBeyondLimitIsRejected() {
        let existingFile = "/Users/dev/project/TMLlaboratory"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let clickedRow = "/Users/dev/project/TMLlaborator"
        let seed = resolver.wrappedPathSeed(in: clickedRow, column: clickedRow.count - 1, cwd: "/tmp")
        guard let seed else {
            Issue.record("Expected a seed for the clicked row")
            return
        }

        let deeplyIndentedAdjacentRow = String(repeating: " ", count: 17) + "y"
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, previousRow: nil, nextRow: deeplyIndentedAdjacentRow, cwd: "/tmp"
            ) == nil
        )
    }

    @Test func oversizedTokenIsRejected() {
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        let oversizedToken = "/" + String(repeating: "a", count: 2000)
        #expect(
            resolver.wrappedPathSeed(in: oversizedToken, column: 0, cwd: "/tmp") == nil
        )
    }

    // Dogfood regression (override skipped 5/8 times despite a correct
    // resolver): Ghostty's own hard-wrap link continuation (`link_wrap.zig`)
    // reports the *whole joined match text* to its `open_url` callback, not
    // just the clicked row's local piece. A single match key missing the
    // adjacent fragment can never equal that callback's raw URL whenever a
    // continuation actually joined two rows, so the exact-match arbitration
    // in `handleCommandClickOpenURLCallback` silently falls through to
    // Ghostty's own (possibly wrong) URL instead of claiming the override.
    // `nativeMatchKeys` covers both native shapes for the winning direction:
    // the full joined candidate, and each of its two raw constituents.
    @Test func nativeMatchKeysCoverTheFullJoinedCandidateAndBothConstituentsForNextDirection() throws {
        let existingFile = "/Users/dev/project/TMLlaboratory"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let clickedRow = "/Users/dev/project/TMLlaborator"
        let seed = try #require(
            resolver.wrappedPathSeed(in: clickedRow, column: clickedRow.count - 1, cwd: "/tmp")
        )
        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: "y", cwd: "/tmp")
        )
        #expect(candidate.nativeMatchKeys == [clickedRow + "y", clickedRow, "y"])
    }

    @Test func nativeMatchKeysJoinFragmentBeforeTokenForPreviousDirection() throws {
        let existingFile = "/Users/dev/project/notes/2026-report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let previousRow = "/Users/dev/project/"
        let clickedRow = "notes/2026-report.md"
        let seed = try #require(
            resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: "/tmp")
        )
        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: "/tmp")
        )
        #expect(candidate.nativeMatchKeys == [previousRow + clickedRow, clickedRow, previousRow])
    }

    // Review requirement: only the *winning* direction's constituents are
    // ever kept. An ambiguous bare-relative seed that only resolves via
    // `.previous` must not leak the rejected `.next` direction's adjacent
    // fragment into the key set — that would let this candidate claim
    // native text belonging to a different, unresolved join.
    @Test func nativeMatchKeysExcludeTheLosingDirectionsFragment() throws {
        let existingFile = "/Users/dev/project/notes/2026-report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let previousRow = "/Users/dev/project/"
        let clickedRow = "notes/2026-report.md"
        let rejectedNextRow = "unrelated-tail-that-does-not-exist"
        let seed = try #require(
            resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: "/tmp")
        )
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed, previousRow: previousRow, nextRow: rejectedNextRow, cwd: "/tmp"
            )
        )
        #expect(candidate.nativeMatchKeys == [previousRow + clickedRow, clickedRow, previousRow])
        #expect(!candidate.nativeMatchKeys.contains(rejectedNextRow))
    }

    @Test func nativeMatchKeysDropDuplicateEntriesWhenTokenAndFragmentCoincide() throws {
        // Token and fragment are, by coincidence, the exact same text — the
        // 3-way key set (candidate, token, fragment) must collapse to the 2
        // distinct entries rather than repeat the shared one.
        let existingFile = "/ab/ab"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let clickedRow = "/ab"
        let seed = try #require(
            resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: "/tmp")
        )
        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: "/ab", cwd: "/tmp")
        )
        #expect(candidate.nativeMatchKeys == ["/ab/ab", "/ab"])
    }

    // Dogfood regression: a hard-wrapped previous row containing multiple
    // `/` characters (not just the single `/` in the v4/v5 "TMLlaborator"
    // fixture) must still join using the *whole* previous row as the
    // fragment, not just the segment after the last `/`. A last-segment-only
    // extraction would produce "notes/...html" (no leading `/`), which the
    // absolute-only guard rejects, silently falling through to Ghostty's own
    // (wrong) bare-relative-path match.
    @Test func previousDirectionJoinsWholeRowWithMultipleSlashes() throws {
        let row1 = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code/research/docs/not"
        let row2 = "es/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let joinedPath = row1 + row2
        let resolver = TerminalPathResolver(fileExists: existsIn([joinedPath]))

        for column in [0, 5, 30, row2.count - 1] {
            let seed = try #require(
                resolver.wrappedPathSeed(in: row2, column: column, cwd: "/tmp"),
                "Expected a seed at column \(column)"
            )
            // row2 is a single bare-relative token touching both
            // boundaries, so the seed is ambiguous; supplying only
            // `previousRow` exercises the `.previous` derivation.
            #expect(seed.directions == [.previous, .next])

            let candidate = try #require(
                resolver.resolveWrappedCandidate(seed: seed, previousRow: row1, nextRow: nil, cwd: "/tmp"),
                "Expected a candidate at column \(column)"
            )
            #expect(candidate.path == joinedPath)
        }
    }
}

@Suite struct TerminalWrappedRelativePathResolutionTests {
    // Review counter-example: two unrelated bare words that happen to
    // concatenate into an existing relative path must not false-positive.
    // The per-fragment existence guard, ASCII, single-candidate, and A-B-A
    // checks don't rule this out on their own since none of them reason
    // about whether the join is a real path shape.
    @Test func unrelatedAdjacentWordsDoNotFalsePositiveOnCoincidentalJoin() {
        let coincidental = "/tmp/foobar"
        let resolver = TerminalPathResolver(fileExists: existsIn([coincidental]))
        let clickedRow = "bar"
        guard let seed = resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: "/tmp") else {
            Issue.record("Expected a seed for the non-slash token")
            return
        }
        #expect(seed.directions == [.previous, .next])
        #expect(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: "foo", nextRow: nil, cwd: "/tmp") == nil
        )
    }

    // Path-shape constraint: a relative candidate with a dotted leaf but no
    // `/` at all is rejected, even though the joined path happens to exist
    // (existence alone is not enough — a bare filename join isn't
    // path-shaped the way Ghostty's own bare_relative_path_branch is).
    @Test func relativeCandidateWithoutSlashIsRejectedByPathShape() {
        let resolver = TerminalPathResolver(fileExists: existsIn(["/tmp/foo.txt"]))
        let clickedRow = ".txt"
        guard let seed = resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: "/tmp") else {
            Issue.record("Expected a seed for the non-slash token")
            return
        }
        #expect(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: "foo", nextRow: nil, cwd: "/tmp") == nil
        )
    }

    // An explicit relative marker (`./`) is allowed even without a dotted
    // leaf requirement being separately satisfied by the marker itself, and
    // the resolved path is the cwd-joined, standardized absolute path —
    // never the raw "./..." string.
    @Test func explicitRelativePrefixIsAllowedAndResolvesToAbsolutePath() throws {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/relproj/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let clickedRow = "t.md"

        let seed = try #require(
            resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd)
        )
        #expect(seed.directions == [.previous, .next])

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: "./relproj/repor", nextRow: nil, cwd: cwd)
        )
        #expect(candidate.path == existingFile)
    }

    // Continuation-side click, bare relative candidate (no explicit marker):
    // contains `/` and has a dotted leaf, so it's path-shaped, and it
    // resolves against cwd to the standardized absolute path.
    @Test func continuationSideRelativeWrapSucceedsWithDottedBareRelative() throws {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/notes/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let clickedRow = "t.md"

        let seed = try #require(
            resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd)
        )
        #expect(seed.directions == [.previous, .next])

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: "notes/repor", nextRow: nil, cwd: cwd)
        )
        #expect(candidate.path == existingFile)
        #expect(candidate.path != "notes/report.md")
    }
}

@Suite struct TerminalWrappedBidirectionalResolutionTests {
    /// Records every path probed via `fileExists`, so tests can assert the
    /// documented per-direction I/O budget (at most one probe for the
    /// adjacent fragment alone and one for the joined candidate, per
    /// direction actually attempted) instead of only asserting the result.
    /// Tests construct the seed through a separate, non-recording resolver
    /// so the row-local check's own probe (a separate budget) never counts
    /// against the wrapped-candidate-phase assertions here.
    private final class ProbeRecorder: @unchecked Sendable {
        private(set) var probedPaths: [String] = []
        private let existingPaths: Set<String>

        init(existingPaths: Set<String>) {
            self.existingPaths = existingPaths
        }

        func fileExists(_ path: String) -> Bool {
            probedPaths.append(path)
            return existingPaths.contains((path as NSString).standardizingPath)
        }
    }

    // Leading-side click: the clicked row is the *start* of a bare-relative
    // path that hard-wrapped ("research/docs/not" / "es/report.html"). The
    // seed is ambiguous (a lone token touches both boundaries), but only
    // the `.next` derivation resolves to an existing file — the supplied
    // `previousRow` doesn't form a dotted, path-shaped join — so exactly
    // one candidate is produced and it's the full joined path.
    @Test func leadingSideClickResolvesViaNextOnlyAndOpensOnce() throws {
        let cwd = "/tmp"
        let existingFile = "/tmp/research/docs/notes/report.html"
        let clickedRow = "research/docs/not"

        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(seedResolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        #expect(seed.directions == [.previous, .next])

        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed,
                previousRow: "unrelated/xyz",
                nextRow: "es/report.html",
                cwd: cwd
            )
        )
        #expect(candidate.path == existingFile)
    }

    // Continuation-side click: the clicked row is the *tail* of the same
    // hard-wrapped path. Only `.previous` resolves — the supplied
    // `nextRow` doesn't form a path-shaped join — so exactly one candidate
    // is produced.
    @Test func continuationSideClickResolvesViaPreviousOnlyAndOpensOnce() throws {
        let cwd = "/tmp"
        let existingFile = "/tmp/research/docs/notes/report.html"
        let clickedRow = "es/report.html"

        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(seedResolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        #expect(seed.directions == [.previous, .next])

        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed,
                previousRow: "research/docs/not",
                nextRow: "unrelated/xyz",
                cwd: cwd
            )
        )
        #expect(candidate.path == existingFile)
    }

    // Both directions resolving to existing files — even to two different
    // paths — is ambiguous and must not open anything. The clicked token
    // itself contains `/` (satisfying `.next`'s leading-piece prefix-shape
    // guard) and the previous row's fragment also contains `/` (satisfying
    // `.previous`'s), so both directions clear every guard independently.
    @Test func bothDirectionsResolvingIsAmbiguousAndOpensNothing() throws {
        let cwd = "/tmp"
        let clickedRow = "mid/dle.txt"
        let previousJoin = "/tmp/a/premid/dle.txt"
        let nextJoin = "/tmp/mid/dle.txt2/b"

        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(seedResolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        #expect(seed.directions == [.previous, .next])

        let resolver = TerminalPathResolver(fileExists: existsIn([previousJoin, nextJoin]))
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed,
                previousRow: "a/pre",
                nextRow: "2/b",
                cwd: cwd
            ) == nil
        )
    }

    // The review counter-example, with a probe-count assertion: the
    // prefix-shape guard rejects the join before any filesystem probe, so
    // the coincidentally-existing `foobar` is never probed.
    @Test func coincidentalJoinIsNeverProbed() throws {
        let cwd = "/tmp"
        let coincidental = "/tmp/foobar"
        let clickedRow = "bar"

        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(seedResolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        #expect(seed.directions == [.previous, .next])

        let recorder = ProbeRecorder(existingPaths: [coincidental])
        let resolver = TerminalPathResolver(fileExists: recorder.fileExists)
        #expect(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: "foo", nextRow: nil, cwd: cwd) == nil
        )
        #expect(recorder.probedPaths.isEmpty)
    }

    // An explicit root/relative prefix seed only ever names `.next`; even
    // when the caller supplies a `previousRow`, the opposite direction is
    // never attempted (no fragment extraction, no probes against it).
    @Test func explicitPrefixSeedNeverProbesThePreviousDirection() throws {
        let cwd = "/tmp"
        let existingFile = "/tmp/relproj/report.md"
        let clickedRow = "./relproj/repor"

        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(seedResolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        #expect(seed.directions == [.next])

        let recorder = ProbeRecorder(existingPaths: [existingFile])
        let resolver = TerminalPathResolver(fileExists: recorder.fileExists)
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed,
                previousRow: "this row is ignored entirely",
                nextRow: "t.md",
                cwd: cwd
            )
        )
        #expect(candidate.path == existingFile)
        // At most 2 probes (fragment alone + joined candidate) — none of
        // them derived from `previousRow`.
        #expect(recorder.probedPaths.count <= 2)
        #expect(!recorder.probedPaths.contains { $0.contains("ignored") })
    }

    // An absolute (`/`-prefixed) seed likewise only ever names `.next` and
    // never probes a `previousRow` the caller might still pass.
    @Test func absolutePrefixSeedNeverProbesThePreviousDirection() throws {
        let existingFile = "/Users/dev/project/TMLlaboratory"
        let clickedRow = "/Users/dev/project/TMLlaborator"

        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(
            seedResolver.wrappedPathSeed(in: clickedRow, column: clickedRow.count - 1, cwd: "/tmp")
        )
        #expect(seed.directions == [.next])

        let recorder = ProbeRecorder(existingPaths: [existingFile])
        let resolver = TerminalPathResolver(fileExists: recorder.fileExists)
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed,
                previousRow: "this row is ignored entirely",
                nextRow: "y",
                cwd: "/tmp"
            )
        )
        #expect(candidate.path == existingFile)
        #expect(recorder.probedPaths.count <= 2)
        #expect(!recorder.probedPaths.contains { $0.contains("ignored") })
    }

    // Ambiguous bare-relative resolution stays within the documented I/O
    // budget: at most 4 probes (2 per direction) even when both directions
    // fully resolve.
    @Test func ambiguousBareRelativeStaysWithinFourProbes() throws {
        let cwd = "/tmp"
        let clickedRow = "mid/dle.txt"
        let previousJoin = "/tmp/a/premid/dle.txt"
        let nextJoin = "/tmp/mid/dle.txt2/b"

        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(seedResolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        #expect(seed.directions == [.previous, .next])

        let recorder = ProbeRecorder(existingPaths: [previousJoin, nextJoin])
        let resolver = TerminalPathResolver(fileExists: recorder.fileExists)
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed,
                previousRow: "a/pre",
                nextRow: "2/b",
                cwd: cwd
            ) == nil
        )
        #expect(recorder.probedPaths.count <= 4)
    }

    // Dogfood regression (issue #8810): the previous row wasn't a bare
    // path — it was a markdown-list-style line labeling several file
    // references ("  - html: /Users/.../docs/not"). Because a single
    // space was tolerated as part of a wrap-continuation fragment (to
    // support multi-word filenames elsewhere), trailingContinuationFragment
    // walked backward straight through "html: " and "- " into the label
    // text, since none of those characters are tabs or doubled spaces.
    // The resulting fragment carried that label prefix into the joined
    // candidate, which then couldn't possibly exist on disk — even though
    // clickedRow/previousRow were read correctly and the *real* joined
    // path (ignoring the label) does exist. Confirmed live via dogfood
    // debug logs: `noCandidate` fired for both directions despite this.
    @Test func dogfoodEvidence1IgnoresLabelPrefixOnPreviousRow() throws {
        let cwd = "/tmp"
        let joinedPath = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code/research/docs/notes/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let clickedRow = "  es/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let previousRow = "  - html: /Users/yosuke/workspace/github.com/TMLlaboratory/s-code/research/docs/not"
        // A real non-ASCII status line from the same dogfood session,
        // included to confirm it doesn't participate (ASCII fail-closed)
        // rather than accidentally supplying a `.next` derivation too.
        let nextRow = "  \u{23FF}  Stop says: \u{26A0} dotfiles \u{306B}\u{672A}\u{30B3}\u{30DF}\u{30C3}\u{30C8}\u{5909}\u{66F4}\u{304C} "

        let resolver = TerminalPathResolver(fileExists: existsIn([joinedPath]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 2, cwd: cwd))
        #expect(seed.directions == [.previous, .next])

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nextRow, cwd: cwd)
        )
        #expect(candidate.path == joinedPath)
    }

    // Dogfood regression, second live example (issue #8810): the *clicked*
    // row itself carried a label prefix ("  - md: /Users/.../notes/202"),
    // so the same single-space-tolerant scan swallowed "- md: " into the
    // token used for the `.next` direction (and, before this fix, made the
    // seed wrongly ambiguous — see below). The real absolute path (minus
    // the label) joins with the next row's continuation and exists.
    @Test func dogfoodEvidence2IgnoresLabelPrefixOnClickedRow() throws {
        let cwd = "/tmp"
        let joinedPath = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let clickedRow = "  - md: /Users/yosuke/workspace/github.com/TMLlaboratory/s-code/research/docs/notes/202"
        let nextRow = "  6-07-31_key_cost_volume_price_and_probability_floor.md"

        let resolver = TerminalPathResolver(fileExists: existsIn([joinedPath]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 12, cwd: cwd))
        // The real path token starts with `/`, so with the label prefix
        // correctly excluded, this must be unambiguously `.next` only —
        // never bidirectional (an explicit root prefix never tries
        // `.previous`, per resolveWrappedCandidate's doc comment).
        #expect(seed.directions == [.next])

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: nextRow, cwd: cwd)
        )
        #expect(candidate.path == joinedPath)
    }
}

// review-slash-boundary-and-codex-comparison.md's 10 required regression
// tests (issue #8810 bug A): a leading piece that ends with an explicit
// `/` continuation seam is stronger join evidence than ordinary mid-word
// adjacency, so it narrowly bypasses (only in that exact shape, only when
// the continuation row is unindented) the two independent points that
// otherwise reject it — `fragmentAloneExists` in
// `resolveSingleDirection` (row2/continuation-side clicks) and the
// row-local short-circuit in `wrappedPathSeed` (row1/leading-side
// clicks). Both fixes are exercised together where useful (tests 1-3, 5)
// so the same directory+file fixture pins the exact click-position
// symmetry the review's root-cause analysis called out.
@Suite struct TerminalSlashSeamContinuationTests {
    // 1. Row2/continuation-side click (review §1-a's exact repro): the
    // previous row's trailing fragment is an existing directory ending in
    // `/`. Before this fix, `fragmentAloneExists` rejected this
    // unconditionally; the explicit, unindented `/` seam now bypasses it.
    @Test func continuationSideClickJoinsThroughAnExistingDirectoryFragment() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let clickedRow = "notes/report.md"
        let joinedFile = previousRow + clickedRow

        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedFile]))
        // Clicking at column 0 keeps the clicked token unindented, which
        // is what makes `.previous`'s explicit-slash-seam bypass apply.
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd)
        )
        #expect(candidate.path == joinedFile)
    }

    // 2. Row1/leading-side click (review §1-b's exact repro): the clicked
    // row itself is an existing directory ending in `/`, which previously
    // made `wrappedPathSeed`'s row-local short-circuit return `nil`
    // outright before ever reaching the resolver's join logic. The
    // narrow provisional-seed exception (unindented `.next` continuation,
    // clicked token ending in `/`) now lets the join through instead.
    @Test func leadingSideClickJoinsThroughARowLocalDirectoryHit() throws {
        let cwd = "/tmp"
        let clickedRow = "/Users/dev/project/research/docs/"
        let nextRow = "notes/report.md"
        let joinedFile = clickedRow + nextRow

        let resolver = TerminalPathResolver(fileExists: existsIn([clickedRow, joinedFile]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 5, cwd: cwd))
        #expect(seed.directions == [.next])

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: nextRow, cwd: cwd)
        )
        #expect(candidate.path == joinedFile)
    }

    // 3. The same link, clicked/hovered from EITHER physical row, must
    // resolve to the identical full path with cell spans that cover the
    // identical two absolute rows/columns — never a different result
    // depending on which half of the wrap was clicked, and never more
    // than the one candidate each click produces (`resolveWrappedCandidate`
    // is structurally exactly-once: it returns non-nil only when exactly
    // one direction succeeds).
    @Test func bothRowsResolveToTheSameFullPathWithSymmetricCellSpans() throws {
        let cwd = "/tmp"
        let directoryRow = "/Users/dev/project/research/docs/"
        let continuationRow = "notes/report.md"
        let joinedFile = directoryRow + continuationRow
        let resolver = TerminalPathResolver(fileExists: existsIn([directoryRow, joinedFile]))

        // Absolute physical rows this fixture stands in for, so each
        // click's row-relative `cellSpans` can be translated to the same
        // coordinate space and compared directly.
        let directoryAbsoluteRow = 5
        let continuationAbsoluteRow = 6

        let leadingSeed = try #require(
            resolver.wrappedPathSeed(in: directoryRow, column: 0, cwd: cwd)
        )
        let leadingCandidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: leadingSeed, previousRow: nil, nextRow: continuationRow, cwd: cwd
            )
        )

        let continuationSeed = try #require(
            resolver.wrappedPathSeed(in: continuationRow, column: 0, cwd: cwd)
        )
        let continuationCandidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: continuationSeed, previousRow: directoryRow, nextRow: nil, cwd: cwd
            )
        )

        #expect(leadingCandidate.path == joinedFile)
        #expect(continuationCandidate.path == joinedFile)

        func absoluteSpans(
            _ candidate: TerminalWrappedPathResolution,
            clickedAbsoluteRow: Int
        ) -> Set<[Int]> {
            Set(candidate.cellSpans.map { span in
                [clickedAbsoluteRow + span.rowOffsetFromClicked, span.startColumn, span.endColumn]
            })
        }

        let leadingAbsoluteSpans = absoluteSpans(leadingCandidate, clickedAbsoluteRow: directoryAbsoluteRow)
        let continuationAbsoluteSpans = absoluteSpans(continuationCandidate, clickedAbsoluteRow: continuationAbsoluteRow)
        #expect(leadingAbsoluteSpans.count == 2)
        #expect(leadingAbsoluteSpans == continuationAbsoluteSpans)
    }

    // 4. A `/`-less existing directory fragment is still rejected exactly
    // as before — the exception is keyed on an explicit `/` seam, never
    // on filesystem kind (review §2's explicitly-rejected "directory ⇒
    // skip the guard" alternative).
    @Test func nonSlashDirectoryFragmentIsStillRejectedByFragmentAloneExists() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/docs"
        let clickedRow = "report.md"

        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        let outcomes = resolver.diagnoseWrappedCandidate(
            seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd
        )
        #expect(outcomes[.previous] == .fragmentAloneExists)
        #expect(resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd) == nil)
    }

    // 5. The unindented condition, pinned directly: the EXACT SAME
    // directory+file fixture as test 1, except the continuation row is
    // indented (mirroring an independent, indented list item after a
    // directory line) — join must NOT happen, matching Ghostty's own
    // `link_wrap.zig` `startsIndependentLink` treating this shape as
    // ambiguous and failing closed, even though both the directory
    // fragment and the joined file genuinely exist on disk.
    @Test func indentedContinuationAfterSlashSeamDoesNotJoin() {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let indentedClickedRow = "    notes/report.md"
        let joinedFile = previousRow + "notes/report.md"

        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedFile]))
        // Clicking within the indentation-shifted token (column 4, where
        // "notes/report.md" actually starts) is what makes the fixture
        // genuinely indented for `.previous`'s seam check.
        guard let seed = resolver.wrappedPathSeed(in: indentedClickedRow, column: 4, cwd: cwd) else {
            Issue.record("Expected a seed for the indented continuation token")
            return
        }

        #expect(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd) == nil
        )
    }

    // 6. Bare-relative dogfood rows (label prefix, ISO date, the exact
    // split position from the live repro) resolve from EITHER row — this
    // is bug B's shape (review §3: "現行 resolver 単体で解決できる"), a
    // non-`/`-seam bare-relative join that must keep working unchanged
    // alongside the new `/`-seam exception.
    @Test func bareRelativeDogfoodRowsResolveFromEitherRow() throws {
        let cwd = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code"
        let leadingRow = "research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floo"
        let continuationRow = "r.md"
        let joinedFile = cwd + "/" + leadingRow + continuationRow
        let resolver = TerminalPathResolver(fileExists: existsIn([joinedFile]))

        let leadingSeed = try #require(resolver.wrappedPathSeed(in: leadingRow, column: 0, cwd: cwd))
        let leadingCandidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: leadingSeed, previousRow: "unrelated/xyz", nextRow: continuationRow, cwd: cwd
            )
        )
        #expect(leadingCandidate.path == joinedFile)

        let continuationSeed = try #require(resolver.wrappedPathSeed(in: continuationRow, column: 0, cwd: cwd))
        let continuationCandidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: continuationSeed, previousRow: leadingRow, nextRow: "unrelated/xyz", cwd: cwd
            )
        )
        #expect(continuationCandidate.path == joinedFile)

        // The label-prefixed clicked-row shape from the live dogfood log
        // (`dogfoodEvidence2IgnoresLabelPrefixOnClickedRow`'s sibling),
        // confirmed against this same split position. The label's
        // non-space characters ("- md: ") break `touchesLeadingBoundary`
        // (which requires the leading run to be pure ASCII spaces), so
        // this is `.next`-only, not ambiguous — same single-direction
        // outcome as the absolute-path label case, for a different
        // structural reason (here: a failed leading-boundary check;
        // there: an explicit root marker).
        let labeledLeadingRow = "  - md: " + leadingRow
        let labeledSeed = try #require(resolver.wrappedPathSeed(in: labeledLeadingRow, column: 12, cwd: cwd))
        #expect(labeledSeed.directions == [.next])
        let labeledCandidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: labeledSeed, previousRow: "unrelated/xyz", nextRow: continuationRow, cwd: cwd
            )
        )
        #expect(labeledCandidate.path == joinedFile)
    }

    // 7. The same bare-relative fixture stays `nil` for every one of the
    // conditions review §3's "次に確認すべきもの" list separates: wrong
    // cwd, no cwd at all ("remote", from this resolver's own perspective
    // — it has no remote concept, only whether a usable cwd is
    // available), a non-ASCII adjacent row, and both directions
    // succeeding (ambiguous).
    @Test func bareRelativeFixtureStaysNilForWrongCwdRemoteNonASCIIAndAmbiguity() throws {
        let realCwd = "/Users/dev/project"
        let leadingRow = "research/docs/notes/report"
        let continuationRow = ".md"
        let joinedFile = realCwd + "/" + leadingRow + continuationRow
        let resolver = TerminalPathResolver(fileExists: existsIn([joinedFile]))

        let seed = try #require(resolver.wrappedPathSeed(in: leadingRow, column: 0, cwd: realCwd))

        // Wrong cwd: the joined candidate resolves against a directory
        // where it doesn't exist.
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, previousRow: nil, nextRow: continuationRow, cwd: "/Users/dev/other-project"
            ) == nil
        )

        // No cwd at all ("remote", from the resolver's own perspective —
        // `probeExists` skips any relative candidate without one).
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, previousRow: nil, nextRow: continuationRow, cwd: ""
            ) == nil
        )

        // Non-ASCII adjacent row: the fragment extractor fails closed,
        // never a `candidateDoesNotExist` masking a real ASCII mismatch.
        let nonASCIIContinuation = "caf\u{e9}.md"
        let nonASCIIOutcomes = resolver.diagnoseWrappedCandidate(
            seed: seed, previousRow: nil, nextRow: nonASCIIContinuation, cwd: realCwd
        )
        #expect(nonASCIIOutcomes[.next] == .noFragment)

        // Both directions succeeding is ambiguous, never a guess.
        let ambiguousClickedRow = "mid/dle.txt"
        let ambiguousSeed = try #require(
            resolver.wrappedPathSeed(in: ambiguousClickedRow, column: 0, cwd: realCwd)
        )
        let ambiguousResolver = TerminalPathResolver(
            fileExists: existsIn(["/Users/dev/project/a/premid/dle.txt", "/Users/dev/project/mid/dle.txt2/b"])
        )
        #expect(
            ambiguousResolver.resolveWrappedCandidate(
                seed: ambiguousSeed, previousRow: "a/pre", nextRow: "2/b", cwd: realCwd
            ) == nil
        )
    }

    // 8. A row-local hit on an ordinary REGULAR FILE (no trailing `/`) is
    // never overridden by an adjacent row, even one shaped like a
    // plausible continuation — the provisional-seed exception is keyed
    // strictly on the clicked token itself ending with `/`.
    @Test func rowLocalRegularFileHitIsNeverOverriddenByAnAdjacentRow() {
        let cwd = "/tmp"
        let existingFile = "/tmp/existing-file.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        #expect(
            resolver.wrappedPathSeed(in: existingFile, column: 2, cwd: cwd) == nil
        )
    }

    // 9. An existing REGULAR FILE (not a directory) as the adjacent
    // fragment is likewise still rejected by `fragmentAloneExists`
    // outside the `/` seam — the exception's scope is the seam shape,
    // never "the fragment happens to exist," directory or otherwise.
    @Test func existingRegularFileFragmentIsStillRejectedOutsideTheSlashSeam() throws {
        let cwd = "/tmp"
        let existingFragmentFile = "/tmp/existing.txt"
        let clickedRow = "tail.md"

        let resolver = TerminalPathResolver(fileExists: existsIn([existingFragmentFile]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        let outcomes = resolver.diagnoseWrappedCandidate(
            seed: seed, previousRow: existingFragmentFile, nextRow: nil, cwd: cwd
        )
        #expect(outcomes[.previous] == .fragmentAloneExists)
    }

    // 10. Integration: the resolved candidate from a `/`-seam join is the
    // single, stable value the rest of the current pipeline consumes —
    // resolving it twice (standing in for a hover preview immediately
    // followed by the click-release re-check
    // `commitWrappedCandidate` performs, per its own doc comment) yields
    // byte-for-byte the same path, match keys, and cell spans each time,
    // with no additional filesystem probes leaking beyond the documented
    // per-direction budget — i.e. nothing about resolving through the new
    // exception makes the pipeline's existing "resolve once, reuse"
    // contracts any less exact.
    @Test func slashSeamCandidateResolvesIdenticallyAndOnceEachTimeForHoverThenClickCommit() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let clickedRow = "notes/report.md"
        let joinedFile = previousRow + clickedRow

        let hoverResolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedFile]))
        let hoverSeed = try #require(hoverResolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        let hoverCandidate = try #require(
            hoverResolver.resolveWrappedCandidate(seed: hoverSeed, previousRow: previousRow, nextRow: nil, cwd: cwd)
        )

        // The click-release re-check: a fresh resolver/seed/call, exactly
        // as `commitWrappedCandidate`'s own doc describes re-probing
        // existence at release time rather than trusting the earlier
        // prepare — never sharing mutable state with the hover call above.
        let releaseResolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedFile]))
        let releaseSeed = try #require(releaseResolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        let releaseCandidate = try #require(
            releaseResolver.resolveWrappedCandidate(
                seed: releaseSeed, previousRow: previousRow, nextRow: nil, cwd: cwd
            )
        )

        #expect(hoverCandidate.path == releaseCandidate.path)
        #expect(hoverCandidate.nativeMatchKeys == releaseCandidate.nativeMatchKeys)
        #expect(hoverCandidate.cellSpans == releaseCandidate.cellSpans)
        #expect(hoverCandidate.path == joinedFile)
    }
}

// Physical-row splitting for `ghostty_surface_read_text_physical_rows`
// output (see `readPhysicalViewportSnapshot` in `GhosttyTerminalView.swift`).
// The API's contract is only "doesn't unwrap soft-wrap boundaries," not a
// guaranteed row count, so this is where the review's four splitting rules
// live: split with empty subsequences kept, strip a trailing newline
// sentinel, pad short results at the end only, and fail closed on anything
// else rather than `prefix(rows)`-truncate and silently misattribute a
// later row's text to an earlier index.
@Suite struct TerminalPhysicalViewportRowSplitTests {
    @Test func exactRowCountRoundTrips() {
        #expect("a\nb\nc".splitPhysicalViewportRows(expectedRows: 3) == ["a", "b", "c"])
    }

    @Test func trailingNewlineSentinelIsStrippedNotCountedAsARow() {
        #expect("a\nb\nc\n".splitPhysicalViewportRows(expectedRows: 3) == ["a", "b", "c"])
    }

    @Test func shortResultIsPaddedAtTheEndOnly() {
        #expect("a\nb".splitPhysicalViewportRows(expectedRows: 4) == ["a", "b", "", ""])
    }

    @Test func leadingAndInnerEmptyRowsSurvive() {
        #expect("\na\n\nb".splitPhysicalViewportRows(expectedRows: 4) == ["", "a", "", "b"])
    }

    @Test func tooManyRowsFailsClosedInsteadOfTruncating() {
        // Two more entries than expected — well past the one-sentinel-entry
        // case, so `prefix(rows)` would silently discard real content
        // instead of surfacing the mismatch.
        #expect("a\nb\nc\nd\ne".splitPhysicalViewportRows(expectedRows: 3) == nil)
    }

    @Test func expectedRowsPlusOneWithNonEmptyLastEntryFailsClosed() {
        // Exactly one more entry than expected, but the last one isn't the
        // empty-string sentinel a trailing newline would produce — some
        // other inconsistency, not the known-safe case.
        #expect("a\nb\nc\nd".splitPhysicalViewportRows(expectedRows: 3) == nil)
    }

    @Test func zeroOrNegativeExpectedRowsFailsClosed() {
        #expect("a".splitPhysicalViewportRows(expectedRows: 0) == nil)
        #expect("a".splitPhysicalViewportRows(expectedRows: -1) == nil)
    }

    @Test func emptyInputPadsAllRowsWhenExpectedRowsPositive() {
        #expect("".splitPhysicalViewportRows(expectedRows: 3) == ["", "", ""])
    }
}
