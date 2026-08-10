import Foundation
import Testing
// design-decision-b1-fallback-policy.md rule 6 — the legacy 2-row
// `resolveWrappedCandidate(seed:previousRow:nextRow:cwd:)` overload is
// `internal`, not `public` (no cross-module production caller may reach
// it directly); this file's white-box fixtures exercise it anyway, so
// this needs `@testable`.
@testable import CmuxTerminalCore

// Two `.unavailableNonASCIIRow` values compare `==` to each other, so a
// bare `cellSpans == cellSpans` equality check can't tell "both sides
// really did compute available columns" apart from "both sides gave up in
// the same way" — exactly the regression this would silently mask for an
// ASCII-only fixture that should never hit the text-only fallback at all.
private func expectAvailableCellSpans(
    _ cellSpans: TerminalWrappedCellSpans,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard case .available = cellSpans else {
        Issue.record("Expected .available cellSpans for an ASCII-only fixture, got \(cellSpans)", sourceLocation: sourceLocation)
        return
    }
}

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
        #expect(candidate.cellSpans == .available([
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 0, startColumn: 0, endColumn: clickedRow.count),
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 1, startColumn: 0, endColumn: 1),
        ]))
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
        #expect(candidate.cellSpans == .available([
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 0, startColumn: 0, endColumn: clickedRow.count),
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: -1, startColumn: 0, endColumn: previousRow.count),
        ]))
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

    // design-next-round-bundle-8810.md §1 (issue #8810 bug B's actual
    // resolution) — a THIRD live dogfood shape, structurally identical to
    // the two above except the previous row is prefixed by Claude Code's
    // own bullet ("●", U+25CF, non-ASCII). Previously pinned as an
    // INTENDED fail-closed (design-answer-bugB-ascii-guard.md): the
    // guarded `trailingContinuationFragmentWithRange()` still returns
    // `nil` for this row, exactly as before — that guard is untouched.
    // What changed is `resolveSingleDirection` no longer stops there for
    // `.previous`: it falls back to
    // ``String/trailingContinuationFragmentText()``, which needs no
    // column projection onto this row at all, so it extracts the SAME
    // trailing fragment text a pure-ASCII row would have yielded. The
    // result carries `cellSpans = .unavailableNonASCIIRow` (never a
    // guessed column range) — this is the click-only path (no `geometry`
    // parameter exists on this legacy 2-row overload at all), so (B)
    // ExternalHover's own consumption gate (`ExternalHoverWorkService`)
    // is what keeps this from ever producing a wrong-positioned
    // underline; this test only proves the resolver's own half.
    //
    // The `.next` direction (row32, pure ASCII) is unaffected and still
    // fails the SAME guard as before — pinned here too, as proof
    // `leadingPieceNotPathPrefixShaped` was never relaxed and the `.next`
    // extractor was never touched.
    @Test func bulletPrefixedPreviousRowResolvesViaTextOnlyOnTheLegacyClickPathNextDirectionUnaffected() throws {
        let cwd = "/tmp/bugB"
        let row30 = "\u{25CF} research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let row31 = "  ility_floor.md"
        let row32 = "  research/docs/notes/2026-07-31_scaffold_kl_foundations_and_meas"
        let trailingFragment = "research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let token = "ility_floor.md"
        let mdFile = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let htmlFile = cwd + "/research/docs/notes/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let resolver = TerminalPathResolver(fileExists: existsIn([mdFile, htmlFile]))

        let seed = try #require(resolver.wrappedPathSeed(in: row31, column: 12, cwd: cwd))
        let outcomes = resolver.diagnoseWrappedCandidate(seed: seed, previousRow: row30, nextRow: row32, cwd: cwd)

        #expect(outcomes[.previous] == .succeeded(TerminalWrappedPathResolution(
            path: mdFile,
            nativeMatchKeys: [trailingFragment + token, token, trailingFragment],
            cellSpans: .unavailableNonASCIIRow
        )))
        #expect(outcomes[.next] == .leadingPieceNotPathPrefixShaped)

        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: row30, nextRow: row32, cwd: cwd)
        )
        #expect(candidate.path == mdFile)
        #expect(candidate.cellSpans == .unavailableNonASCIIRow)
    }

    // final-spec §3.2 rule 2 — `.rowLocalHitAwaitingMirrorSlashSeam`
    // must NEVER fall back to an ordinary cross-row search just because
    // the clicked token's own leading piece happens to be path-prefix-
    // shaped: row0 ("a/foo") is a row-local hit reaching the strict
    // right edge, `cwd/a/foo` exists (making it a row-local hit at all),
    // AND the coincidentally-joined candidate `cwd/a/fooaRest` ALSO
    // exists — but row1 ("aRest") doesn't start with `/`, so the
    // boundary immediately after the clicked row never satisfies
    // `mirrorSlashSeam`. Without rule 2's gating, the ordinary evaluator
    // would happily adopt this span (the leading piece "a/foo" already
    // contains `/`, satisfying `leadingPieceNotPathPrefixShaped` on its
    // own) — exactly the filesystem-coincidence override final-spec
    // §3.1/§3.2 exist to forbid for a row-local hit.
    @Test func rowLocalHitAwaitingMirrorSlashSeamNeverAdoptsAnOrdinaryCoincidentalJoin() throws {
        let cwd = "/tmp"
        let rows = ["a/foo", "aRest"]
        let parentDirectory = "/tmp/a/foo"
        let coincidentalJoin = "/tmp/a/fooaRest"
        let resolver = TerminalPathResolver(fileExists: existsIn([parentDirectory, coincidentalJoin]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        // columns: 5 — "a/foo" (5 chars) must reach the strict right
        // edge for `wrappedPathSeed` to reach the disposition at all.
        let seed = try #require(resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd, columns: 5))
        let window = try #require(TerminalPhysicalRowWindow(rows: rows, clickedIndex: 0, columns: 5))
        #expect(resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry) == nil)

        // The legacy 2-row overload must independently reject this too
        // (evaluateWrappedCandidate's own disposition guard) — it has no
        // `columns` to evaluate `mirrorSlashSeam` at all, so it can never
        // legitimately satisfy rule 2, regardless of what `nextRow` is.
        #expect(resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: rows[1], cwd: cwd) == nil)
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
            guard case .available(let spans) = candidate.cellSpans else {
                Issue.record("Expected .available cellSpans for an ASCII-only fixture")
                return []
            }
            return Set(spans.map { span in
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
        expectAvailableCellSpans(hoverCandidate.cellSpans)
        #expect(hoverCandidate.path == joinedFile)
    }
}

// final-spec-scope-expansion-8810.md §10/§14 — bug A's 10 fixtures above
// (`TerminalSlashSeamContinuationTests`), each re-run through the
// geometry-aware, window-based overload. The legacy result remains the
// parity oracle for the existing shapes; fixture #5 is the intentional
// symptom-2 exception because the geometry evaluator now accepts its
// bounded leading indentation while the legacy pin stays nil.
// Fixture #8 (`rowLocalRegularFileHitIsNeverOverriddenByAnAdjacentRow`)
// only exercises `wrappedPathSeed` (never reaches `resolveWrappedCandidate`
// at all), so there is nothing to parameterize — 9 of the 10 apply here.
@Suite struct TerminalSlashSeamGeometryParityTests {
    private let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

    // 1. continuationSideClickJoinsThroughAnExistingDirectoryFragment
    @Test func fixture1ContinuationSideClickAgreesWithLegacy() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let clickedRow = "notes/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, previousRow + clickedRow]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        let legacy = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd)
        )
        let window = try #require(
            TerminalPhysicalRowWindow(rows: [previousRow, clickedRow], clickedIndex: 1, columns: previousRow.count)
        )
        let viaGeometry = try #require(
            resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        )
        #expect(viaGeometry.path == legacy.path)
        #expect(viaGeometry.cellSpans == legacy.cellSpans)
        expectAvailableCellSpans(legacy.cellSpans)
        #expect(viaGeometry.nativeMatchKeys == legacy.nativeMatchKeys)
    }

    // 2. leadingSideClickJoinsThroughARowLocalDirectoryHit
    @Test func fixture2LeadingSideClickAgreesWithLegacy() throws {
        let cwd = "/tmp"
        let clickedRow = "/Users/dev/project/research/docs/"
        let nextRow = "notes/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([clickedRow, clickedRow + nextRow]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 5, cwd: cwd))

        let legacy = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: nextRow, cwd: cwd)
        )
        let window = try #require(
            TerminalPhysicalRowWindow(rows: [clickedRow, nextRow], clickedIndex: 0, columns: clickedRow.count)
        )
        let viaGeometry = try #require(
            resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        )
        #expect(viaGeometry.path == legacy.path)
        #expect(viaGeometry.cellSpans == legacy.cellSpans)
        expectAvailableCellSpans(legacy.cellSpans)
        #expect(viaGeometry.nativeMatchKeys == legacy.nativeMatchKeys)
    }

    // 3. bothRowsResolveToTheSameFullPathWithSymmetricCellSpans
    @Test func fixture3BothClickedRowsAgreeWithLegacy() throws {
        let cwd = "/tmp"
        let directoryRow = "/Users/dev/project/research/docs/"
        let continuationRow = "notes/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([directoryRow, directoryRow + continuationRow]))
        let window = try #require(
            TerminalPhysicalRowWindow(
                rows: [directoryRow, continuationRow], clickedIndex: 0, columns: directoryRow.count
            )
        )

        let leadingSeed = try #require(resolver.wrappedPathSeed(in: directoryRow, column: 0, cwd: cwd))
        let leadingLegacy = try #require(
            resolver.resolveWrappedCandidate(seed: leadingSeed, previousRow: nil, nextRow: continuationRow, cwd: cwd)
        )
        let leadingViaGeometry = try #require(
            resolver.resolveWrappedCandidate(seed: leadingSeed, window: window, cwd: cwd, geometry: geometry)
        )
        #expect(leadingViaGeometry.path == leadingLegacy.path)
        #expect(leadingViaGeometry.cellSpans == leadingLegacy.cellSpans)
        expectAvailableCellSpans(leadingLegacy.cellSpans)
        #expect(leadingViaGeometry.nativeMatchKeys == leadingLegacy.nativeMatchKeys)

        let continuationSeed = try #require(resolver.wrappedPathSeed(in: continuationRow, column: 0, cwd: cwd))
        let continuationWindow = try #require(
            TerminalPhysicalRowWindow(
                rows: [directoryRow, continuationRow], clickedIndex: 1, columns: directoryRow.count
            )
        )
        let continuationLegacy = try #require(
            resolver.resolveWrappedCandidate(seed: continuationSeed, previousRow: directoryRow, nextRow: nil, cwd: cwd)
        )
        let continuationViaGeometry = try #require(
            resolver.resolveWrappedCandidate(seed: continuationSeed, window: continuationWindow, cwd: cwd, geometry: geometry)
        )
        #expect(continuationViaGeometry.path == continuationLegacy.path)
        #expect(continuationViaGeometry.cellSpans == continuationLegacy.cellSpans)
        expectAvailableCellSpans(continuationLegacy.cellSpans)
        #expect(continuationViaGeometry.nativeMatchKeys == continuationLegacy.nativeMatchKeys)
    }

    // 4. nonSlashDirectoryFragmentIsStillRejectedByFragmentAloneExists
    @Test func fixture4NonSlashFragmentStaysNilViaGeometryToo() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/docs"
        let clickedRow = "report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        #expect(resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd) == nil)
        let window = try #require(
            TerminalPhysicalRowWindow(rows: [previousRow, clickedRow], clickedIndex: 1, columns: previousRow.count)
        )
        #expect(resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry) == nil)
    }

    // 5. indentedContinuationAfterSlashSeamDoesNotJoin
    @Test func fixture5IndentedContinuationUsesBoundedLeadingSeamViaGeometry() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let indentedClickedRow = "    notes/report.md"
        let joinedFile = previousRow + "notes/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedFile]))
        let seed = try #require(resolver.wrappedPathSeed(in: indentedClickedRow, column: 4, cwd: cwd))

        #expect(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd) == nil
        )
        let window = try #require(
            TerminalPhysicalRowWindow(
                rows: [previousRow, indentedClickedRow], clickedIndex: 1, columns: previousRow.count
            )
        )
        let viaGeometry = try #require(
            resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        )
        #expect(viaGeometry.path == joinedFile)
        expectAvailableCellSpans(viaGeometry.cellSpans)
    }

    // 6. bareRelativeDogfoodRowsResolveFromEitherRow (leading/continuation
    // resolves only — the labeled-clicked-row sub-case is covered
    // qualitatively elsewhere and isn't re-checked here).
    @Test func fixture6BareRelativeDogfoodRowsAgreeWithLegacy() throws {
        let cwd = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code"
        let leadingRow = "research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floo"
        let continuationRow = "r.md"
        let joinedFile = cwd + "/" + leadingRow + continuationRow
        let resolver = TerminalPathResolver(fileExists: existsIn([joinedFile]))
        let window = try #require(
            TerminalPhysicalRowWindow(rows: [leadingRow, continuationRow], clickedIndex: 0, columns: leadingRow.count)
        )

        let leadingSeed = try #require(resolver.wrappedPathSeed(in: leadingRow, column: 0, cwd: cwd))
        let leadingLegacy = try #require(
            resolver.resolveWrappedCandidate(
                seed: leadingSeed, previousRow: "unrelated/xyz", nextRow: continuationRow, cwd: cwd
            )
        )
        let leadingViaGeometry = try #require(
            resolver.resolveWrappedCandidate(seed: leadingSeed, window: window, cwd: cwd, geometry: geometry)
        )
        #expect(leadingViaGeometry.path == leadingLegacy.path)
        #expect(leadingViaGeometry.cellSpans == leadingLegacy.cellSpans)
        expectAvailableCellSpans(leadingLegacy.cellSpans)
        #expect(leadingViaGeometry.nativeMatchKeys == leadingLegacy.nativeMatchKeys)

        let continuationSeed = try #require(resolver.wrappedPathSeed(in: continuationRow, column: 0, cwd: cwd))
        let continuationWindow = try #require(
            TerminalPhysicalRowWindow(rows: [leadingRow, continuationRow], clickedIndex: 1, columns: leadingRow.count)
        )
        let continuationLegacy = try #require(
            resolver.resolveWrappedCandidate(
                seed: continuationSeed, previousRow: leadingRow, nextRow: "unrelated/xyz", cwd: cwd
            )
        )
        let continuationViaGeometry = try #require(
            resolver.resolveWrappedCandidate(seed: continuationSeed, window: continuationWindow, cwd: cwd, geometry: geometry)
        )
        #expect(continuationViaGeometry.path == continuationLegacy.path)
        #expect(continuationViaGeometry.cellSpans == continuationLegacy.cellSpans)
        expectAvailableCellSpans(continuationLegacy.cellSpans)
        #expect(continuationViaGeometry.nativeMatchKeys == continuationLegacy.nativeMatchKeys)
    }

    // 7. bareRelativeFixtureStaysNilForWrongCwdRemoteNonASCIIAndAmbiguity
    // (wrong-cwd and no-cwd sub-cases only).
    @Test func fixture7WrongCwdAndNoCwdStayNilViaGeometryToo() throws {
        let realCwd = "/Users/dev/project"
        let leadingRow = "research/docs/notes/report"
        let continuationRow = ".md"
        let joinedFile = realCwd + "/" + leadingRow + continuationRow
        let resolver = TerminalPathResolver(fileExists: existsIn([joinedFile]))
        let seed = try #require(resolver.wrappedPathSeed(in: leadingRow, column: 0, cwd: realCwd))
        let window = try #require(
            TerminalPhysicalRowWindow(rows: [leadingRow, continuationRow], clickedIndex: 0, columns: leadingRow.count)
        )

        for wrongCwd in ["/Users/dev/other-project", ""] {
            #expect(
                resolver.resolveWrappedCandidate(
                    seed: seed, previousRow: nil, nextRow: continuationRow, cwd: wrongCwd
                ) == nil
            )
            #expect(
                resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: wrongCwd, geometry: geometry) == nil
            )
        }
    }

    // 9. existingRegularFileFragmentIsStillRejectedOutsideTheSlashSeam
    @Test func fixture9ExistingRegularFileFragmentStaysNilViaGeometryToo() throws {
        let cwd = "/tmp"
        let existingFragmentFile = "/tmp/existing.txt"
        let clickedRow = "tail.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFragmentFile]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        #expect(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: existingFragmentFile, nextRow: nil, cwd: cwd)
                == nil
        )
        let window = try #require(
            TerminalPhysicalRowWindow(
                rows: [existingFragmentFile, clickedRow], clickedIndex: 1, columns: existingFragmentFile.count
            )
        )
        #expect(resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry) == nil)
    }

    // 10. slashSeamCandidateResolvesIdenticallyAndOnceEachTimeForHoverThenClickCommit
    @Test func fixture10HoverThenClickCommitAgreesWithLegacy() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let clickedRow = "notes/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, previousRow + clickedRow]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        let legacy = try #require(
            resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd)
        )
        let window = try #require(
            TerminalPhysicalRowWindow(rows: [previousRow, clickedRow], clickedIndex: 1, columns: previousRow.count)
        )
        let viaGeometry = try #require(
            resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        )
        #expect(viaGeometry.path == legacy.path)
        #expect(viaGeometry.cellSpans == legacy.cellSpans)
        expectAvailableCellSpans(legacy.cellSpans)
        #expect(viaGeometry.nativeMatchKeys == legacy.nativeMatchKeys)
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

// impl-slashseam-and-diagnostics — bug B diagnostics (issue #8810,
// review §"次に確認すべきもの" item 1). `diagnoseSeedAbsence` classifies
// WHY `wrappedPathSeed` returned `nil`, purely for DEBUG dogfood log
// triage — it never changes what `wrappedPathSeed` itself decides, so
// each case here double-checks that against the real method too.
@Suite struct TerminalSeedAbsenceDiagnosisTests {
    @Test func classifiesColumnOutOfBounds() {
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        #expect(resolver.diagnoseSeedAbsence(in: "short", column: 99, cwd: "/tmp") == "columnOutOfBounds")
        #expect(resolver.wrappedPathSeed(in: "short", column: 99, cwd: "/tmp") == nil)
    }

    @Test func classifiesNonASCIIRow() {
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        let row = "/Users/dev/caf\u{e9}proj"
        #expect(resolver.diagnoseSeedAbsence(in: row, column: 5, cwd: "/tmp") == "nonASCIIRow")
        #expect(resolver.wrappedPathSeed(in: row, column: 5, cwd: "/tmp") == nil)
    }

    @Test func classifiesNoBoundaryTouched() {
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        let row = "foo\tbar\tbaz"
        #expect(resolver.diagnoseSeedAbsence(in: row, column: 4, cwd: "/tmp") == "noBoundaryTouched")
        #expect(resolver.wrappedPathSeed(in: row, column: 4, cwd: "/tmp") == nil)
    }

    @Test func classifiesPlainRowLocalHit() {
        let existingFile = "/tmp/cmux-wrap-row-local.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        #expect(
            resolver.diagnoseSeedAbsence(in: existingFile, column: 2, cwd: "/tmp")
                == "rowLocalHitNotExplicitSlashSeam"
        )
        #expect(resolver.wrappedPathSeed(in: existingFile, column: 2, cwd: "/tmp") == nil)
    }

    @Test func classifiesNonFullRowLocalHitWithMirrorSeamMargin() {
        let existingFile = "/tmp/row-local.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        #expect(
            resolver.diagnoseSeedAbsence(in: existingFile, column: 2, cwd: "/tmp", columns: 80)
                == "rowLocalHitMirrorSeamNotFull gridColumns=80 clickedLastCol=16 fullnessMargin=63"
        )
        #expect(resolver.wrappedPathSeed(in: existingFile, column: 2, cwd: "/tmp", columns: 80) == nil)
    }

    // The narrow exception itself must NOT be classified as an absence —
    // `wrappedPathSeed` returns a real (provisional) seed for this shape,
    // so `diagnoseSeedAbsence` is never even called for it in practice;
    // this only confirms the two methods' decisions stay in sync.
    @Test func explicitSlashSeamRowLocalHitIsNotAnAbsence() {
        let directoryRow = "/Users/dev/project/research/docs/"
        let resolver = TerminalPathResolver(fileExists: existsIn([directoryRow]))
        #expect(resolver.wrappedPathSeed(in: directoryRow, column: 5, cwd: "/tmp") != nil)
    }
}

// impl-bugB-diagnostics-v2 — format/consistency checks only, no resolver
// heuristic change (task's own boundary). `evaluateWrappedCandidate` must
// make the EXACT same decision `resolveWrappedCandidate`/
// `diagnoseWrappedCandidate` already did (it now delegates to it), and
// `diagnoseCandidateShape` must report accurate, non-raw shape flags,
// including for a direction the real resolution stops short of.
@Suite struct TerminalWrappedCandidateDiagnosticsV2Tests {
    @Test func evaluateWrappedCandidateMatchesTheExistingPublicAPIsExactly() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let clickedRow = "notes/report.md"
        let joinedFile = previousRow + clickedRow
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedFile]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        let evaluated = resolver.evaluateWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd)
        let resolved = resolver.resolveWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd)
        let diagnosed = resolver.diagnoseWrappedCandidate(seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd)

        #expect(evaluated.candidate == resolved)
        #expect(evaluated.outcomes == diagnosed)
        #expect(evaluated.candidate?.path == joinedFile)
    }

    @Test func diagnoseCandidateShapeReportsAccurateNonRawFlagsPastAFailingGuard() throws {
        // The review's own counter-example shape: clicked token alone
        // doesn't exist, adjacent fragment alone doesn't exist, but the
        // fragment has no `/` or `.` so `leadingPieceIsPathPrefixShaped`
        // is false for `.previous` — the exact guard the real resolution
        // stops at (`leadingPieceNotPathPrefixShaped`), while the
        // diagnostic still reports every other flag past it.
        let cwd = "/tmp"
        let clickedRow = "bar"
        let previousRow = "foo"
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        let shape = resolver.diagnoseCandidateShape(
            seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd,
            cellRow: 5, cellColumn: 0, gridColumns: 80
        )

        #expect(shape.cellRow == 5)
        #expect(shape.cellColumn == 0)
        #expect(shape.gridColumns == 80)
        #expect(shape.tokenShape.length == 3)
        #expect(shape.tokenShape.containsSlash == false)
        #expect(shape.tokenShape.containsDot == false)
        #expect(shape.tokenShape.firstCharacterClass == .alphanumeric)

        let previousDiagnostic = try #require(shape.directions[.previous])
        #expect(previousDiagnostic.outcome == .leadingPieceNotPathPrefixShaped)
        let fragmentShape = try #require(previousDiagnostic.fragmentShape)
        #expect(fragmentShape.length == 3)
        #expect(fragmentShape.containsSlash == false)
        #expect(previousDiagnostic.leadingPieceIsPathPrefixShaped == false)
        // Computed PAST the failing guard, purely for diagnosis — the
        // real resolution never reaches these two checks for this
        // direction, but the diagnostic still reports them.
        #expect(previousDiagnostic.candidateIsPathShaped == false)
        #expect(previousDiagnostic.fragmentAloneExists == false)
        #expect(previousDiagnostic.candidateExists == false)
    }

    @Test func diagnoseCandidateShapeReportsNoColumnShapeWhenOnlyTextOnlyExtractionSucceeds() throws {
        let cwd = "/tmp"
        let clickedRow = "notes/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        // A non-ASCII previous row fails the GUARDED, column-ranged
        // extraction this shape diagnostic itself uses (unchanged) — but
        // `resolveSingleDirection`'s own `outcome` (design-next-round-
        // bundle-8810.md §1) now falls back to text-only extraction, so
        // it's no longer `.noFragment`: "café" IS a real fragment now,
        // it just isn't shaped like a path prefix (no `/`, no marker).
        // `fragmentShape`/the flags past it stay `nil` regardless — this
        // diagnostic only ever reports COLUMN shape, which text-only
        // extraction structurally cannot supply.
        let shape = resolver.diagnoseCandidateShape(
            seed: seed, previousRow: "caf\u{e9}", nextRow: nil, cwd: cwd,
            cellRow: 0, cellColumn: 0, gridColumns: 40
        )
        let previousDiagnostic = try #require(shape.directions[.previous])
        #expect(previousDiagnostic.outcome == .leadingPieceNotPathPrefixShaped)
        #expect(previousDiagnostic.fragmentShape == nil)
        #expect(previousDiagnostic.leadingPieceIsPathPrefixShaped == nil)
        #expect(previousDiagnostic.candidateIsPathShaped == nil)
        #expect(previousDiagnostic.fragmentAloneExists == nil)
        #expect(previousDiagnostic.candidateExists == nil)
    }

    @Test func geometryOutcomePreservesFullnessRejectionForDiagnostics() throws {
        let cwd = "/tmp"
        let previousRow = "/tmp/prefix/"
        let clickedRow = "file.txt"
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow + clickedRow]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))

        let outcome = try #require(
            resolver.evaluateWrappedCandidateOutcome(
                seed: seed,
                rows: [previousRow, clickedRow],
                clickedIndex: 1,
                columns: 80,
                cwd: cwd
            )
        )
        #expect(outcome == .rejected(.fullnessGuardRejected))
    }
}

// cmux-shared-behavior policy — the shared `resolveWrappedCandidate(seed:
// rows:clickedIndex:columns:cwd:purpose:)` entry point both the click and
// hover production call sites now go through, instead of each choosing
// its own overload independently.
@Suite struct TerminalSharedResolutionEntryPointTests {
    @Test func verifiedNarrowScalarMembershipAndMeasurementMetadataStayPinned() {
        let metadata = TerminalRowCellLayout.measuredNarrowScalarMetadata
        #expect(metadata.map { $0.scalar.value } == [0x2022, 0x25CF, 0x25A0, 0x25CB, 0x2B24])
        #expect(Set(metadata.map(\.ghosttyCommit)) == ["abcf5697d4fcd05e29a83ccfc090d6e234952849"])
        #expect(Set(metadata.map(\.measuredOn)) == ["2026-08-09"])
        #expect(Set(metadata.map(\.method)) == [
            "ghostty/src/unicode/main.zig codepointWidth() via zig build test"
        ])
        #expect(TerminalRowCellLayout.verified(for: "•●■○⬤") != nil)
        #expect(TerminalRowCellLayout.verified(for: "●︎") == nil)
        #expect(TerminalRowCellLayout.verified(for: "●\tpath") == nil)
        #expect(TerminalRowCellLayout.verified(for: "エラー: /tmp/path") == nil)
    }

    @Test func clickResolvesBulletPrefixedLeadingRowThroughTextOnlyFallback() throws {
        let cwd = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code"
        let clickedRow = "● research/docs/notes/2026-07-31_key_cost_volume_price"
        let nextRow = "_and_probability_floor.md"
        let expectedPath = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))

        let resolution = try #require(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 19,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            )
        )
        #expect(resolution.path == expectedPath)
        #expect(resolution.cellSpans == .available([
            TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: 0,
                startColumn: 2,
                endColumn: clickedRow.count
            ),
            TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: 1,
                startColumn: 0,
                endColumn: nextRow.count
            ),
        ]))
    }

    @Test func hoverUsesTheVerifiedBulletLeadingRowFallbackWithExactCellSpans() throws {
        let cwd = "/tmp/leading-row"
        let clickedRow = "● research/docs/notes/2026-07-31_key_cost_volume_price"
        let nextRow = "_and_probability_floor.md"
        let expectedPath = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))

        let resolution = try #require(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 12,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .hover
            )
        )
        #expect(resolution.path == expectedPath)
        #expect(resolution.cellSpans == .available([
            TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: 0,
                startColumn: 2,
                endColumn: clickedRow.count
            ),
            TerminalWrappedPathCellSpan(
                rowOffsetFromClicked: 1,
                startColumn: 0,
                endColumn: nextRow.count
            ),
        ]))
    }

    @Test func leadingRowFallbackRejectsMultiplePathShapedBodyTokens() {
        let cwd = "/tmp/leading-row"
        let clickedRow = "● research/docs/notes/price /tmp/other"
        let nextRow = "  .md"
        let firstCandidate = cwd + "/research/docs/notes/price.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([firstCandidate]))

        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 12,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            ) == nil
        )
    }

    @Test func leadingRowFallbackRejectsClickInNonASCIIOrPrefixRegion() {
        let cwd = "/tmp/leading-row"
        let clickedRow = "● research/docs/notes/2026-07-31_key_cost_volume_price"
        let nextRow = "_and_probability_floor.md"
        let expectedPath = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))

        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 0,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            ) == nil
        )
    }

    @Test func leadingRowFallbackRejectsExistingRowLocalTokenBeforeJoining() {
        let cwd = "/tmp"
        let clickedRow = "● /tmp/dir suffix"
        let nextRow = "file.md"
        let rowLocalPath = "/tmp/dir"
        let joinedPath = "/tmp/dirfile.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([rowLocalPath, joinedPath]))

        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 10,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            ) == nil
        )
    }

    @Test func leadingRowFallbackRejectsAmbiguousBulletSecondCell() {
        let cwd = "/tmp"
        let clickedRow = "● research/docs/price"
        let nextRow = ".md"
        let expectedPath = cwd + "/research/docs/price.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))

        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 1,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            ) == nil
        )
    }

    @Test func verifiedBulletWithVariationSelectorStaysConservativeAndClickOnly() throws {
        let cwd = "/tmp/leading-row"
        let clickedRow = "●︎ research/docs/price"
        let nextRow = ".md"
        let expectedPath = cwd + "/research/docs/price.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))

        let clickResolution = try #require(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 4,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            )
        )
        #expect(clickResolution.path == expectedPath)
        #expect(clickResolution.cellSpans == .unavailableNonASCIIRow)
        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 4,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .hover
            ) == nil
        )
    }

    @Test func CJKPrefixStaysConservativeAndClickOnly() throws {
        let cwd = "/tmp/leading-row"
        let clickedRow = "エラー: /tmp/foo"
        let nextRow = ".md"
        let expectedPath = "/tmp/foo.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))

        let clickResolution = try #require(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 8,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            )
        )
        #expect(clickResolution.path == expectedPath)
        #expect(clickResolution.cellSpans == .unavailableNonASCIIRow)
        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 8,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .hover
            ) == nil
        )
    }

    @Test func tabInBodyStaysConservativeAndClickOnly() throws {
        let cwd = "/tmp/leading-row"
        let clickedRow = "● research/docs/price\t"
        let nextRow = ".md"
        let expectedPath = cwd + "/research/docs/price.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))

        let clickResolution = try #require(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 2,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            )
        )
        #expect(clickResolution.path == expectedPath)
        #expect(clickResolution.cellSpans == .unavailableNonASCIIRow)
        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 2,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .hover
            ) == nil
        )
    }

    @Test func leadingRowFallbackRejectsNonASCIIInsideTheBody() {
        let cwd = "/tmp/leading-row"
        let clickedRow = "● research/docs/notes/price_日本"
        let nextRow = "  .md"
        let resolver = TerminalPathResolver(fileExists: existsIn([cwd + "/research/docs/notes/price_日本.md"]))

        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 12,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            ) == nil
        )
    }

    @Test func leadingRowFallbackNeverExtendsPastItsTwoRowSpan() {
        let cwd = "/tmp/leading-row"
        let clickedRow = "● research/docs/notes/price"
        let nextRow = "  _and_probability_floor"
        let threeRowPath = cwd + "/research/docs/notes/price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([threeRowPath]))

        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 12,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            ) == nil
        )
    }

    @Test func leadingRowFallbackLeavesPreviousRowFallbackUnchanged() throws {
        let cwd = "/tmp/leading-row"
        let previousRow = "● research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let clickedRow = "  ility_floor.md"
        let nextRow = "  unrelated status"
        let expectedPath = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 4, cwd: cwd, columns: 65))

        let resolution = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed,
                rows: [previousRow, clickedRow, nextRow],
                clickedIndex: 1,
                columns: 65,
                cwd: cwd,
                purpose: .click
            )
        )
        #expect(resolution.path == expectedPath)
        #expect(resolution.cellSpans == .unavailableNonASCIIRow)
    }

    @Test func allASCIILeadingRowStillUsesTheExistingSeedPath() throws {
        let cwd = "/tmp/leading-row"
        let clickedRow = "research/docs/notes/price"
        let nextRow = "  _and_probability_floor.md"
        let expectedPath = cwd + "/research/docs/notes/price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedPath]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 12, cwd: cwd))

        let regularResolution = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed,
                previousRow: nil,
                nextRow: nextRow,
                cwd: cwd
            )
        )
        #expect(regularResolution.path == expectedPath)
        #expect(
            resolver.resolveTextOnlyLeadingRowFallback(
                clickedRow: clickedRow,
                column: 12,
                nextRow: nextRow,
                cwd: cwd,
                purpose: .click
            ) == nil
        )
    }

    // design-decision-b1-fallback-policy.md rule 2 — bug B's non-ASCII
    // `.previous` row IS the narrow, click-only fallback exception: the
    // geometry-aware evaluator can't judge it at all (row30 is
    // non-ASCII), and every one of rule 2's other conditions holds (a
    // 2-row `.previous`-only join, ASCII clicked row), so `purpose:
    // .click` reaches `resolveTextOnlyPreviousFallback` and resolves it —
    // required test 2 from design-decision-b1-fallback-policy.md.
    @Test func clickResolvesTheBugBTextOnlyFixtureViaTheNarrowFallback() throws {
        let cwd = "/tmp/bugB"
        let row30 = "\u{25CF} research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let row31 = "  ility_floor.md"
        let row32 = "  research/docs/notes/2026-07-31_scaffold_kl_foundations_and_meas"
        let mdFile = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let htmlFile = cwd + "/research/docs/notes/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let resolver = TerminalPathResolver(fileExists: existsIn([mdFile, htmlFile]))
        // Exact dogfood-shaped surrounding output: only the immediate
        // previous row is consumed by the winning previous fallback.
        // Japanese UI/status text in the rest of the 7-row window must not
        // make this two-row decision fail closed.
        let rows = [
            "● 以下が最新のノートのパスです。",
            "  現在からの相対pathで noteを出して．",
            row30,
            row31,
            row32,
            "  └ Stop says: ⚠ dotfiles に未コミット変更が 1",
            "    件あります (claude/settings.json …) 。symlink 管理のため commit を忘れずに。",
        ]

        let seed = try #require(resolver.wrappedPathSeed(in: row31, column: 12, cwd: cwd, columns: 65))
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 3, columns: 65, cwd: cwd, purpose: .click
            )
        )
        #expect(candidate.path == mdFile)
        #expect(candidate.cellSpans == .unavailableNonASCIIRow)
    }

    // design-decision-b1-fallback-policy.md rule 2 condition 2 — required
    // test 3: hover can NEVER reach the fallback, even for the identical
    // fixture click just resolved above.
    @Test func hoverNeverResolvesTheBugBTextOnlyFixtureEvenThoughClickDoes() throws {
        let cwd = "/tmp/bugB"
        let row30 = "\u{25CF} research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let row31 = "  ility_floor.md"
        let row32 = "  research/docs/notes/2026-07-31_scaffold_kl_foundations_and_meas"
        let mdFile = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let htmlFile = cwd + "/research/docs/notes/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let resolver = TerminalPathResolver(fileExists: existsIn([mdFile, htmlFile]))
        let rows = [row30, row31, row32]

        let seed = try #require(resolver.wrappedPathSeed(in: row31, column: 12, cwd: cwd, columns: 65))
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, rows: rows, clickedIndex: 1, columns: 65, cwd: cwd, purpose: .hover
        )
        #expect(candidate == nil)
    }

    // design-decision-b1-fallback-policy.md rule 5/B1's own regression —
    // required test 1, THE most load-bearing test in this whole set: a
    // fullness-rejected, ALL-ASCII 2-row pair whose joined candidate
    // exists on disk must NEVER open, through EITHER purpose, even though
    // the (now internal) legacy overload alone would happily resolve it.
    // Without this test, B1 could regress silently and nobody would
    // notice until a coincidental adjacent-text match opened the wrong
    // file in production.
    @Test func fullnessRejectedAllASCIICandidateNeverFallsBackForEitherPurpose() throws {
        let cwd = "/tmp"
        let clickedRow = "short"
        let nextRow = "tail.md"
        let coincidental = "/tmp/shorttail.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([coincidental]))
        let rows = [clickedRow, nextRow]

        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        // A wide grid (80 columns) makes `short`'s 5 characters nowhere
        // near the physical edge — the fullness guard rejects this
        // outright; the legacy 2-row overload alone (no fullness concept
        // at all) would still resolve it, which is exactly the bug B1
        // fixed.
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 0, columns: 80, cwd: cwd, purpose: .click
            ) == nil
        )
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 0, columns: 80, cwd: cwd, purpose: .hover
            ) == nil
        )
    }

    // design-decision-b1-fallback-policy.md rule 2 condition 4 — required
    // test 4: even where a real 3-row-spanning file DOES exist, the
    // narrow fallback can only ever attempt an immediate 2-row join
    // (structurally — it calls the legacy 2-row evaluator, never
    // anything wider), so it must return `nil` here rather than somehow
    // reaching past the non-ASCII adjacent row to the real answer.
    @Test func nonASCIIPreviousRowNeedingAThreeRowSpanNeverFallsBackToATwoRowJoin() throws {
        let cwd = "/tmp/case4"
        let rowFar = "docs/"
        let rowNear = "\u{25CF} deep/tail"
        let rowClicked = "report.md"
        // The REAL file exists only at the full 3-row join — genuinely
        // unreachable by this click today (a known, accepted gap per
        // design-decision-b1-fallback-policy.md's closing note: retired
        // once native boundary provenance lands). What matters here is
        // that the coincidental 2-row-only join (`rowNear`'s own trailing
        // fragment + the clicked token) is NOT registered as existing.
        let realThreeRowFile = cwd + "/docs/deep/tailreport.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([realThreeRowFile]))
        let rows = [rowFar, rowNear, rowClicked]

        let seed = try #require(resolver.wrappedPathSeed(in: rowClicked, column: 0, cwd: cwd))
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, rows: rows, clickedIndex: 2, columns: 5, cwd: cwd, purpose: .click
        )
        #expect(candidate == nil)
    }

    // design-decision-b1-fallback-policy.md rule 2 condition 3 (via
    // resolveSingleDirection's own `.next`-never-text-only rule) —
    // required test 8: an absolute, `.next`-only token whose continuation
    // row is non-ASCII must never fall back, since the winning direction
    // would have to be `.next`, which the narrow fallback never accepts.
    @Test func nextDirectionNonASCIIContinuationRowNeverFallsBack() throws {
        let cwd = "/tmp/case8"
        let clickedRow = "/research/"
        let nextRow = "\u{25CF} docs/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([cwd + "/research/docs/report.md"]))
        let rows = [clickedRow, nextRow]

        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        #expect(seed.directions == [.next])
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, rows: rows, clickedIndex: 0, columns: clickedRow.count, cwd: cwd, purpose: .click
        )
        #expect(candidate == nil)
    }

    // review R2-B1/design-decision-b1-fallback-policy.md rule 2
    // condition 6 — only rows whose information the fallback consumes
    // must be ASCII: the clicked row, plus the next row when the seed
    // names `.next`; the previous row is the text-only exception and
    // unrelated rows are ignored. `row32` is a DIFFERENT non-ASCII row
    // (not the original bug-B fixture's ASCII `row32`) with no candidate
    // registered for it. Because this seed names `.next`, that unreadable
    // next row must still make the fallback fail closed rather than
    // allowing the previous-only success.
    @Test func nonASCIINextRowAlongsideANonASCIIPreviousRowNeverFallsBack() throws {
        let cwd = "/tmp/bugB"
        let row30 = "\u{25CF} research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let row31 = "  ility_floor.md"
        let row32 = "\u{25CF} unrelated"
        let mdFile = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        // Only the previous+clicked join is registered — `row32` names
        // no candidate anywhere, unlike the original bug-B fixture whose
        // ASCII `row32` had its own `.next`-direction candidate.
        let resolver = TerminalPathResolver(fileExists: existsIn([mdFile]))
        let rows = [row30, row31, row32]

        let seed = try #require(resolver.wrappedPathSeed(in: row31, column: 12, cwd: cwd, columns: 65))
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 1, columns: 65, cwd: cwd, purpose: .click
            ) == nil
        )
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 1, columns: 65, cwd: cwd, purpose: .hover
            ) == nil
        )
    }

    @Test func previousOnlyFallbackIgnoresNonASCIINextRow() throws {
        let cwd = "/tmp/bugB"
        let previousRow = "\u{25CF} research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let clickedRow = "  ility_floor.md suffix"
        let nextRow = "● unrelated status"
        let mdFile = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([mdFile]))

        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 2, cwd: cwd, columns: 65))
        #expect(seed.directions == [.previous])
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: [previousRow, clickedRow, nextRow], clickedIndex: 1,
                columns: 65, cwd: cwd, purpose: .click
            )
        )
        #expect(candidate.path == mdFile)
        #expect(candidate.cellSpans == .unavailableNonASCIIRow)
    }

    @Test func nextFallbackFailsClosedWhenNextRowIsOutsideTheWindow() throws {
        let cwd = "/tmp/bugB"
        let previousRow = "\u{25CF} research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let clickedRow = "  ility_floor.md"
        let mdFile = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([mdFile]))

        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 2, cwd: cwd, columns: 65))
        #expect(seed.directions == [.previous, .next])
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: [previousRow, clickedRow], clickedIndex: 1,
                columns: 65, cwd: cwd, purpose: .click
            ) == nil
        )
    }

    // The 3-row mirror fixture, clicked from row0: the geometry-aware
    // evaluator DOES resolve this (once `wrappedPathSeed` reaches the
    // row0 disposition), so this entry point must return that result
    // directly, without ever reaching the legacy fallback.
    @Test func resolvesThroughTheGeometryAwareEvaluatorForTheMirrorFixture() throws {
        let cwd = "/tmp"
        let rows = ["foo", "/bar/", "baz.md"]
        let expectedCandidate = "/tmp/foo/bar/baz.md"
        let resolver = TerminalPathResolver(fileExists: existsIn(["/tmp/foo", expectedCandidate]))

        let seed = try #require(resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd, columns: 3))
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 0, columns: 3, cwd: cwd, purpose: .click
            )
        )
        #expect(candidate.path == expectedCandidate)
    }

    // A caller (click) may hand this a window far larger than the
    // evaluator needs (e.g. its whole viewport capture) — this must
    // slice down to the shared ±3-row policy itself rather than reject
    // it or hand `TerminalPhysicalRowWindow` more than its own
    // `maxSnapshotRows` (7) cap allows.
    @Test func slicesAnOversizedRowsArrayDownToTheSharedWindowPolicy() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let clickedRow = "notes/report.md"
        let joinedFile = previousRow + clickedRow
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedFile]))

        // 12 rows total (far past `maxSnapshotRows`), clicked row at
        // index 6 — the real previous/next rows sit right next to it.
        var rows = (0..<12).map { "padding\($0)" }
        rows[5] = previousRow
        rows[6] = clickedRow

        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 6, columns: previousRow.count, cwd: cwd, purpose: .click
            )
        )
        #expect(candidate.path == joinedFile)
    }

    // design-decision-b1-fallback-policy.md rule 2 condition 5 — required
    // test 5: a non-ASCII CLICKED row never even produces a seed at all
    // (`wrapContinuationToken`'s own ASCII guard, `String+TerminalPathTokens.
    // swift`), so there is nothing to hand this entry point in the first
    // place — pinning that this invariant (clicked row ASCII) continues
    // to hold upstream of the whole shared-entry/fallback pipeline.
    @Test func nonASCIIClickedRowNeverProducesASeedAtAll() {
        let cwd = "/tmp/case5"
        let clickedRow = "\u{25CF} report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([cwd + "/report.md"]))
        #expect(resolver.wrappedPathSeed(in: clickedRow, column: 2, cwd: cwd) == nil)
    }

    // design-decision-b1-fallback-policy.md rule 1 — required test 6: two
    // genuinely incomparable (neither containing the other) ASCII 2-row
    // successes on either side of the clicked row must reject, not guess
    // — and, being all-ASCII, must never be confused with the
    // click-only, non-ASCII fallback either.
    @Test func genuinelyAmbiguousSpansNeverFallBackForEitherPurpose() throws {
        let cwd = "/tmp/case6"
        let previousRow = "a/pre"
        let clickedRow = "mid/x.txt"
        let nextRow = "y/z.md"
        let previousCandidate = cwd + "/a/premid/x.txt"
        let nextCandidate = cwd + "/mid/x.txty/z.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([previousCandidate, nextCandidate]))
        let rows = [previousRow, clickedRow, nextRow]

        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        #expect(seed.directions == [.previous, .next])
        // columns: 5 — both `previousRow` (index 4) and `clickedRow`
        // (index 8, already past it) reach the strict right edge, so
        // BOTH the (previous, clicked) and (clicked, next) 2-row spans
        // are independently eligible and independently resolve — neither
        // contains the other's row range.
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 1, columns: 5, cwd: cwd, purpose: .click
            ) == nil
        )
        #expect(
            resolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 1, columns: 5, cwd: cwd, purpose: .hover
            ) == nil
        )
    }

    // review R2-B2/design-decision-b1-fallback-policy.md rule 1 —
    // required test 7: an all-ASCII, multi-row fixture where the REAL
    // winning candidate exists on disk, but a small INJECTED probe
    // budget (the package-internal `maxProbes` overload, review
    // R2-B2's test-only seam) is exhausted by two earlier, genuinely-
    // nonexistent candidates before the search ever reaches it — the
    // evaluator must never fall back to the legacy overload for either
    // purpose in that case, and the recorder confirms the winning
    // candidate's own `fileExists` call never happened at all (not that
    // it happened and returned false).
    //
    // `re/sea.x` (unlike the plain `re/sea` used elsewhere) carries its
    // own `.` so every prefix join from `spanStart == 0` is
    // `isWrappedPathCandidateShaped`-eligible regardless of how far the
    // span extends — the ORIGINAL fixture's shorter joins failed that
    // shape guard before ever calling `probe`, which is exactly why it
    // never spent more than a handful of probes.
    @Test func probeBudgetExhaustionNeverFallsBackForEitherPurpose() throws {
        let cwd = "/tmp/case7"
        let rows = ["re/sea.x", "rch/do", "cs/rep", "ort.md"]
        let realWinningCandidate = cwd + "/re/sea.xrch/docs/report.md"

        final class ProbeRecorder: @unchecked Sendable {
            private(set) var probedPaths: [String] = []
            private let existingPaths: Set<String>
            init(existingPaths: Set<String>) { self.existingPaths = existingPaths }
            func fileExists(_ path: String) -> Bool {
                probedPaths.append(path)
                return existingPaths.contains((path as NSString).standardizingPath)
            }
        }
        // Seed built through a separate, non-recording resolver — its
        // own row-local probe must never count against this budget.
        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        let seed = try #require(seedResolver.wrappedPathSeed(in: rows[1], column: 0, cwd: cwd))

        let maxProbes = 2

        let clickRecorder = ProbeRecorder(existingPaths: [realWinningCandidate])
        let clickResolver = TerminalPathResolver(fileExists: clickRecorder.fileExists)
        #expect(
            clickResolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 1, columns: 6, cwd: cwd, purpose: .click, maxProbes: maxProbes
            ) == nil
        )
        // The injected budget was spent EXACTLY (not under, not over) —
        // confirming the search genuinely ran out, rather than finding
        // its own nil answer within a budget that happened not to bind.
        #expect(clickRecorder.probedPaths.count == maxProbes)
        // The strongest assertion: the real winning candidate's own
        // `fileExists` call is simply absent — exhaustion denied it
        // before the probe could even run, not after a false result.
        #expect(!clickRecorder.probedPaths.contains(realWinningCandidate))

        let hoverRecorder = ProbeRecorder(existingPaths: [realWinningCandidate])
        let hoverResolver = TerminalPathResolver(fileExists: hoverRecorder.fileExists)
        #expect(
            hoverResolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 1, columns: 6, cwd: cwd, purpose: .hover, maxProbes: maxProbes
            ) == nil
        )
        #expect(hoverRecorder.probedPaths.count == maxProbes)

        // Sanity: with the REAL 15-probe budget (production's default,
        // no override), this exact fixture resolves normally — proving
        // the `nil` above is caused by the injected small budget, not by
        // some other property of the fixture.
        let sanityResolver = TerminalPathResolver(fileExists: existsIn([realWinningCandidate]))
        #expect(
            sanityResolver.resolveWrappedCandidate(
                seed: seed, rows: rows, clickedIndex: 1, columns: 6, cwd: cwd, purpose: .click
            )?.path == realWinningCandidate
        )
    }
}
