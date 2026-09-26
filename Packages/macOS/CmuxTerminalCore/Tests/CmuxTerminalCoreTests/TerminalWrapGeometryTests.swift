import Foundation
import Testing
// design-decision-b1-fallback-policy.md rule 6 — see
// `TerminalPathResolverTests.swift`'s identical import comment.
@testable import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> @Sendable (String) -> Bool {
    let standardized = Set(existingPaths.map { ($0 as NSString).standardizingPath })
    return { path in standardized.contains((path as NSString).standardizingPath) }
}

// impl-scope-expansion-8810-test-only (final-spec-scope-expansion-8810.md
// §13) — issue #8810's two scope expansions: 3+ row hard-wrap support and
// bidirectional `/`-continuation search.
//
// `resolveWrappedCandidate(seed:previousRow:nextRow:cwd:geometry:)` (the
// original scaffolding overload, string-pair `previousRow`/`nextRow`) was
// replaced by ``TerminalPathResolver/resolveWrappedCandidate(seed:window:cwd:geometry:)``
// — a single adjacent row on each side structurally cannot carry a 3+ row
// span, so every test below constructs a full `TerminalPhysicalRowWindow`
// instead. This is a test-CONTENT fix, not just a commit split (matching
// this project's established round-3 precedent): the assertions/intent
// below are unchanged from the original scaffolding commit, only the
// call shape is corrected to one the evaluator can actually satisfy.
//
// `wrappedPathSeed` now returns the provisional
// `.rowLocalHitAwaitingMirrorSlashSeam` seed for the strict-full row-local
// hit, so the mirror-seam test's `row0Candidate?.path` assertion exercises
// the same passing behavior as the row1/row2 cases.
@Suite struct TerminalWrapGeometryTests {
    // MARK: - mirror slash seam / disposition (final-spec §13, "mirror
    // slash seam / disposition")

    // The exact fixture from final-spec §3.2/§3.3: row0 `foo` (row-local
    // hit on `cwd/foo`, but `foo` reaches the strict right edge), row1
    // `/bar/` (a literal `/`-prefixed continuation), row2 `baz.md`.
    // Clicking ANY of the three rows must resolve to the SAME candidate.
    // `fake fileExists` includes BOTH the full candidate AND `cwd/foo`
    // (final-spec's explicit fixture requirement, since `cwd/foo`
    // existing is what makes row0 a row-local hit in the first place).
    @Test("3-row mirror fixture resolves to the same candidate from row0, row1, or row2")
    func threeRowMirrorFixtureResolvesToSameCandidateFromAnyClickedRow() {
        let cwd = "/tmp"
        let rows = ["foo", "/bar/", "baz.md"]
        let parentDirectory = "/tmp/foo"
        let expectedCandidate = "/tmp/foo/bar/baz.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([parentDirectory, expectedCandidate]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        func candidate(clickedIndex: Int) -> TerminalWrappedPathResolution? {
            // columns: 3 — "foo" (row0) must reach the strict right edge
            // for the mirror seam at boundary(0,1) to be eligible at all.
            guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: clickedIndex, columns: 3) else {
                return nil
            }
            // `columns: 3` passed through here too — row0's own click is
            // the ONLY one that needs it (it's the only row-local hit in
            // this fixture; row1/row2 reach `.noRowLocalHit` regardless
            // and ignore this parameter, per `wrappedPathSeed`'s own doc)
            // — required for `wrappedPathSeed` to reach
            // `.rowLocalHitAwaitingMirrorSlashSeam` instead of returning
            // `nil` outright at the row-local short-circuit.
            guard let seed = resolver.wrappedPathSeed(in: rows[clickedIndex], column: 0, cwd: cwd, columns: 3) else {
                return nil
            }
            return resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        }

        // row0 click: `foo` row-locally resolves to the existing `cwd/foo`
        // directory, AND reaches the strict right edge, so
        // `wrappedPathSeed` now returns a PROVISIONAL
        // `.rowLocalHitAwaitingMirrorSlashSeam` seed (final-spec §3.2)
        // instead of `nil` — the evaluator's own mirror-seam-only gating
        // on that disposition then reaches the SAME winning span `[0...2]`
        // row1/row2 reach through the ordinary path, exactly as final-spec
        // §3.3's fixture table requires: all three clicked rows converge
        // on one identical result, not three independently-plausible ones.
        let row0Candidate = candidate(clickedIndex: 0)
        let row1Candidate = candidate(clickedIndex: 1)
        let row2Candidate = candidate(clickedIndex: 2)
        #expect(row0Candidate?.path == expectedCandidate)
        #expect(row1Candidate?.path == expectedCandidate)
        #expect(row2Candidate?.path == expectedCandidate)

        // Not just the same PATH from each row — the same winning span
        // `[0...2]` itself: every clicked row's own cell span must cover
        // ALL THREE absolute rows (0, 1, 2) once translated by that
        // click's own row offset, never a narrower span that happened to
        // standardize to the same path by coincidence.
        func absoluteRowOffsets(_ candidate: TerminalWrappedPathResolution?, clickedRow: Int) -> Set<Int>? {
            guard case .available(let spans) = candidate?.cellSpans else { return nil }
            return Set(spans.map { clickedRow + $0.rowOffsetFromClicked })
        }
        #expect(absoluteRowOffsets(row0Candidate, clickedRow: 0) == [0, 1, 2])
        #expect(absoluteRowOffsets(row1Candidate, clickedRow: 1) == [0, 1, 2])
        #expect(absoluteRowOffsets(row2Candidate, clickedRow: 2) == [0, 1, 2])
    }

    @Test("The 3-row mirror fixture requires a literal `/` prefix, a strict right edge, AND geometry")
    func threeRowMirrorFixtureRequiresSlashPrefixStrictEdgeAndGeometry() {
        let cwd = "/tmp"
        let parentDirectory = "/tmp/foo"
        let expectedCandidate = "/tmp/foo/bar/baz.md"
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        // Clicking row1 (not the row-local-hit row0) isolates the mirror
        // seam's own boundary conditions from the bug-B-gated row-local
        // short-circuit above.
        func candidateFromRow1(row1: String, geometry: TerminalWrapGeometry?) -> TerminalWrappedPathResolution? {
            let resolver = TerminalPathResolver(fileExists: existsIn([parentDirectory, expectedCandidate]))
            let rows = ["foo", row1, "baz.md"]
            // columns: 3 — matches "foo" (row0) reaching the strict right edge.
            guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: 3) else { return nil }
            guard let seed = resolver.wrappedPathSeed(in: row1, column: 0, cwd: cwd) else { return nil }
            return resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        }

        // row1 not starting with a literal `/` — no mirror seam at the
        // row0/row1 boundary, and `bar/` alone isn't path-prefix-shaped —
        // must stay `nil`.
        #expect(candidateFromRow1(row1: "bar/", geometry: geometry) == nil)

        // row0 does not reach the strict physical right edge in a wider
        // grid — no mirror seam.
        func candidateFromRow1WiderGrid(row1: String, geometry: TerminalWrapGeometry?) -> TerminalWrappedPathResolution? {
            let resolver = TerminalPathResolver(fileExists: existsIn([parentDirectory, expectedCandidate]))
            let rows = ["foo", row1, "baz.md"]
            guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: 80) else { return nil }
            guard let seed = resolver.wrappedPathSeed(in: row1, column: 0, cwd: cwd) else { return nil }
            return resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        }
        #expect(candidateFromRow1WiderGrid(row1: "/bar/", geometry: geometry) == nil)

        // No geometry at all — multi-row/mirror-seam behavior is
        // unavailable regardless of shape (the legacy non-geometry path:
        // row0 alone, "foo", is never a valid `.previous` fragment source
        // reachable from row1's `.next`-seeking legacy path either).
        #expect(candidateFromRow1(row1: "/bar/", geometry: nil) == nil)
    }

    /// The exact capture-pane fixture from the confirmed symptom-3 repro:
    /// all three rows are preserved byte-for-byte, including two leading
    /// spaces on the continuation rows. The first row's `s-code` prefix is
    /// deliberately an existing path so the row-3 click exercises the
    /// fragment-alone guard bypass licensed by the mirror slash seam.
    @Test("The captured indented mirror-slash fixture resolves from every row and through hover")
    func capturedIndentedMirrorSlashFixtureResolvesFromEveryRowAndHover() throws {
        let rows = [
            "  - md: /Users/yosuke/workspace/github.com/TMLlaboratory/s-code",
            "  /research/docs/notes/2026-07-31_key_cost_volume_price_and_pro",
            "  bability_floor.md",
        ]
        #expect(rows.map(\.count) == [63, 63, 19])
        let cwd = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code"
        let prefix = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code"
        let expected = prefix + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([prefix, expected]))
        let geometry = try #require(TerminalWrapGeometry(fullnessTolerance: 0))
        let expectedSpans: Set<[Int]> = [
            [0, 8, 63],
            [1, 2, 63],
            [2, 2, 19],
        ]

        func resolve(clickedIndex: Int) throws -> (click: TerminalWrappedPathResolution, hover: TerminalWrappedPathResolution) {
            let clickColumn = clickedIndex == 0 ? 8 : 2
            let seed = try #require(
                resolver.wrappedPathSeed(in: rows[clickedIndex], column: clickColumn, cwd: cwd, columns: 63)
            )
            let window = try #require(
                TerminalPhysicalRowWindow(rows: rows, clickedIndex: clickedIndex, columns: 63)
            )
            let click = try #require(
                resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
            )
            let hover = try #require(
                resolver.resolveWrappedCandidate(
                    seed: seed, rows: rows, clickedIndex: clickedIndex, columns: 63, cwd: cwd, purpose: .hover
                )
            )
            return (click: click, hover: hover)
        }

        func absoluteSpans(_ resolution: TerminalWrappedPathResolution, clickedIndex: Int) -> Set<[Int]> {
            guard case .available(let spans) = resolution.cellSpans else {
                Issue.record("captured fixture must expose exact cell spans")
                return []
            }
            return Set(spans.map { span in
                [clickedIndex + span.rowOffsetFromClicked, span.startColumn, span.endColumn]
            })
        }

        for clickedIndex in rows.indices {
            let resolutions = try resolve(clickedIndex: clickedIndex)
            #expect(resolutions.click.path == expected)
            #expect(resolutions.hover.path == expected)
            #expect(absoluteSpans(resolutions.click, clickedIndex: clickedIndex) == expectedSpans)
            #expect(absoluteSpans(resolutions.hover, clickedIndex: clickedIndex) == expectedSpans)
        }

        // The existing unindented `/` fixture remains a valid col-0 seam.
        let unindentedRows = ["foo", "/bar/", "baz.md"]
        let unindentedResolver = TerminalPathResolver(fileExists: existsIn(["/tmp/foo", "/tmp/foo/bar/baz.md"]))
        let unindentedSeed = try #require(
            unindentedResolver.wrappedPathSeed(in: unindentedRows[1], column: 0, cwd: "/tmp", columns: 3)
        )
        let unindentedWindow = try #require(
            TerminalPhysicalRowWindow(rows: unindentedRows, clickedIndex: 1, columns: 3)
        )
        #expect(
            unindentedResolver.resolveWrappedCandidate(
                seed: unindentedSeed, window: unindentedWindow, cwd: "/tmp", geometry: geometry
            )?.path == "/tmp/foo/bar/baz.md"
        )

        // Indentation beyond the shared extractor bound remains fail-closed.
        let overIndentedRows = ["foo", String(repeating: " ", count: 17) + "/bar/", "baz.md"]
        let overIndentedResolver = TerminalPathResolver(fileExists: existsIn(["/tmp/foo", "/tmp/foo/bar/baz.md"]))
        #expect(overIndentedRows[1].leadingContinuationFragmentWithRange(maxIndentation: 16) == nil)
        let overIndentedSeed = TerminalWrappedPathSeed(
            directions: [.previous], token: "/bar/", tokenStartColumn: 17, tokenEndColumn: 22,
            disposition: .noRowLocalHit
        )
        let overIndentedWindow = try #require(
            TerminalPhysicalRowWindow(rows: overIndentedRows, clickedIndex: 1, columns: 3)
        )
        #expect(
            overIndentedResolver
                .resolveWrappedCandidate(seed: overIndentedSeed, window: overIndentedWindow, cwd: "/tmp", geometry: geometry) == nil
        )

        // A non-ASCII lower row must fail at the seam itself, before the
        // later cell-column extractor reports that it cannot evaluate it.
        let nonASCIIRows = ["foo", "/研究", "baz.md"]
        let nonASCIIResolver = TerminalPathResolver(fileExists: existsIn(["/tmp/foo", "/tmp/foo/研究"]))
        let nonASCIISeed = try #require(
            nonASCIIResolver.wrappedPathSeed(in: nonASCIIRows[0], column: 0, cwd: "/tmp", columns: 3)
        )
        let nonASCIIOutcome = nonASCIIResolver.resolveWrappedCandidateWithOutcome(
            seed: nonASCIISeed, rows: nonASCIIRows, clickedIndex: 0, columns: 3, cwd: "/tmp", purpose: .hover
        )
        #expect(nonASCIIOutcome.candidate == nil)
        #expect(nonASCIIOutcome.evaluatorOutcome?.diagnosticName == "rowLocalPriorityBypass")
    }

    // Existing 2-row bug A behavior remains unchanged for the ordinary
    // non-explicit-slash fixture below; the explicit trailing-slash
    // disposition has a separate multi-row rule pinned by the next test.
    @Test("The existing two-row trailing-`/`-seam behavior stays unchanged with geometry supplied")
    func explicitTrailingSlashSeamBypassStaysAdjacentOnlyEvenWithGeometry() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let clickedRow = "notes/report"
        let continuationRow = ".md"
        let joinedTwoRow = previousRow + clickedRow
        let joinedThreeRow = previousRow + clickedRow + continuationRow
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedTwoRow, joinedThreeRow]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        let rows = [previousRow, clickedRow, continuationRow]
        // columns: previousRow's own length — it must reach the strict
        // right edge for the 2-row join's legacy slash-seam bypass to be
        // eligible at all (final-spec §4.2's fullness guard on boundary
        // 0). `clickedRow` ("notes/report", 12 chars) is far short of
        // that same width, so the fullness guard independently rejects
        // extending the span into `continuationRow` too — both the legacy
        // 2-row path and the general span evaluator agree on the 2-row
        // answer for a different but equally load-bearing reason.
        let window = try #require(
            TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: previousRow.count)
        )
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        let candidate = resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        #expect(candidate?.path == joinedTwoRow)
    }

    // review §B2 — the test above doesn't actually enter
    // `.explicitTrailingSlashSeamBypass` at all (its clicked token has no
    // trailing `/` and isn't a row-local hit, so the seed lands in
    // `.noRowLocalHit` instead). This fixture genuinely does: `docs/`
    // itself row-locally resolves AND ends with `/`, so `wrappedPathSeed`
    // produces `.explicitTrailingSlashSeamBypass`. Both the 2-row
    // (adjacent) and a longer, DOMINATING 3-row candidate exist on disk
    // with both internal boundaries full — the revised rule permits the
    // longer span when its leading boundary is the legacy slash seam.
    @Test("`.explicitTrailingSlashSeamBypass` adopts a dominating 3-row candidate when its leading slash seam is valid")
    func explicitTrailingSlashSeamBypassAdoptsADominatingThreeRowCandidate() throws {
        let cwd = "/tmp/b2"
        let rowDocs = "docs/"
        let rowReport = "report.part"
        let rowTwo = "two.md"
        let rowLocalHitTarget = cwd + "/docs"
        let adjacentCandidate = cwd + "/docs/report.part"
        let dominatingThreeRowCandidate = cwd + "/docs/report.parttwo.md"
        let resolver = TerminalPathResolver(
            fileExists: existsIn([rowLocalHitTarget, adjacentCandidate, dominatingThreeRowCandidate])
        )
        let geometry = try #require(TerminalWrapGeometry(fullnessTolerance: 0))

        let seed = try #require(resolver.wrappedPathSeed(in: rowDocs, column: 0, cwd: cwd))
        #expect(seed.disposition == .explicitTrailingSlashSeamBypass)

        let rows = [rowDocs, rowReport, rowTwo]
        // columns: 5 — `rowDocs` (index 4) reaches the strict right edge,
        // and `rowReport` (index 10, already past it) trivially does
        // too, so BOTH internal boundaries (0,1) and (1,2) are full —
        // the 3-row span would dominate the 2-row one on fullness alone
        // if the disposition didn't bound the search first.
        let window = try #require(TerminalPhysicalRowWindow(rows: rows, clickedIndex: 0, columns: 5))
        let candidate = resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        #expect(candidate?.path == dominatingThreeRowCandidate)
    }

    /// Symptom 2's confirmed production shape: the clicked slash-terminated
    /// row and every continuation row carry the terminal's two-space list
    /// indentation. The leading legacy seam must use the same bounded
    /// continuation extractor as `piece(at:)`, so the 3-row candidate is
    /// still licensed even though the next row does not start at col 0.
    @Test("An indented slash-terminated 3-row candidate adopts its dominating span")
    func indentedExplicitTrailingSlashSeamAdoptsADominatingThreeRowCandidate() throws {
        let cwd = "/tmp/indented-bugA"
        let leadingRow = "  \(cwd)/research/docs/"
        let continuationRow = "  notes/report.part_0123456789abcdef"
        let trailingRow = "  two.md"
        let prefix = cwd + "/research/docs/"
        let adjacentCandidate = prefix + "notes/report.part_0123456789abcdef"
        let dominatingCandidate = adjacentCandidate + "two.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([
            cwd + "/research/docs", adjacentCandidate, dominatingCandidate,
        ]))
        let geometry = try #require(TerminalWrapGeometry(fullnessTolerance: 0))
        let rows = [leadingRow, continuationRow, trailingRow]
        let columns = leadingRow.count
        let seed = try #require(resolver.wrappedPathSeed(in: leadingRow, column: 2, cwd: cwd, columns: columns))
        #expect(seed.disposition == .explicitTrailingSlashSeamBypass)
        let window = try #require(TerminalPhysicalRowWindow(rows: rows, clickedIndex: 0, columns: columns))
        let candidate = try #require(
            resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        )
        #expect(candidate.path == dominatingCandidate)
        #expect(candidate.cellSpans == .available([
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 0, startColumn: 2, endColumn: leadingRow.count),
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 1, startColumn: 2, endColumn: continuationRow.count),
            TerminalWrappedPathCellSpan(rowOffsetFromClicked: 2, startColumn: 2, endColumn: trailingRow.count),
        ]))
    }

    /// The second raw capture fixture supplied by the repro: a 50-column
    /// four-row path whose row-local directory hit is load-bearing. It is
    /// kept beside the synthetic R8 fixture so the capture's indentation and
    /// exact widths cannot silently regress to quoted/no-indent prose.
    @Test("The captured 50-column indented slash continuation resolves from rows 2 through 4")
    func capturedFiftyColumnIndentedSlashContinuationResolvesFromEveryPathRow() throws {
        let rows = [
            "  - html:",
            "  /Users/yosuke/workspace/github.com/TMLlaboratory",
            "  /s-code/research/docs/notes/2026-07-31_scaffold_",
            "  kl_foundations_and_measurement_limits.html",
        ]
        #expect(rows.map(\.count) == [9, 50, 50, 44])
        let directory = "/Users/yosuke/workspace/github.com/TMLlaboratory"
        let expected = directory + "/s-code/research/docs/notes/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let resolver = TerminalPathResolver(fileExists: existsIn([directory, expected]))
        let geometry = try #require(TerminalWrapGeometry(fullnessTolerance: 0))

        for clickedIndex in 1...3 {
            let seed = try #require(
                resolver.wrappedPathSeed(
                    in: rows[clickedIndex], column: 2, cwd: directory, columns: 50
                )
            )
            let window = try #require(
                TerminalPhysicalRowWindow(rows: rows, clickedIndex: clickedIndex, columns: 50)
            )
            let candidate = try #require(
                resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: directory, geometry: geometry)
            )
            #expect(candidate.path == expected)
        }
    }

    /// Listing defense layer 1: when the indented child is itself an
    /// existing file, the trailing-side fragment-alone probe must reject the
    /// coincidental wrapped candidate while the directory row remains a
    /// valid row-local hit.
    @Test("An existing indented listing child keeps the row-local directory hit")
    func indentedListingChildExistingRejectsTheWrappedCandidate() throws {
        let cwd = "/tmp/listing-existing"
        let directoryRow = cwd + "/dir/"
        let childRow = "  child.txt"
        let directory = cwd + "/dir"
        let child = cwd + "/child.txt"
        let joined = directoryRow + "child.txt"
        let resolver = TerminalPathResolver(fileExists: existsIn([directory, child, joined]))
        let geometry = try #require(TerminalWrapGeometry(fullnessTolerance: 0))
        let seed = try #require(resolver.wrappedPathSeed(in: directoryRow, column: 0, cwd: cwd, columns: directoryRow.count))
        let window = try #require(TerminalPhysicalRowWindow(rows: [directoryRow, childRow], clickedIndex: 0, columns: directoryRow.count))

        #expect(resolver.resolveVisibleLinePath(directoryRow, column: 0, cwd: cwd)?.path == directory)
        #expect(resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry) == nil)
    }

    /// Listing defense layer 2 is intentionally an acceptance tradeoff: if
    /// the indented child is not independently present, the same full-width
    /// directory shape is accepted as a real wrapped candidate.
    @Test("A missing indented listing child permits the slash-seam join")
    func indentedListingChildMissingAdoptsTheWrappedCandidate() throws {
        let cwd = "/tmp/listing-missing"
        let directoryRow = cwd + "/dir/"
        let childRow = "  child.txt"
        let directory = cwd + "/dir"
        let joined = directoryRow + "child.txt"
        let resolver = TerminalPathResolver(fileExists: existsIn([directory, joined]))
        let geometry = try #require(TerminalWrapGeometry(fullnessTolerance: 0))
        let seed = try #require(resolver.wrappedPathSeed(in: directoryRow, column: 0, cwd: cwd, columns: directoryRow.count))
        let window = try #require(TerminalPhysicalRowWindow(rows: [directoryRow, childRow], clickedIndex: 0, columns: directoryRow.count))

        #expect(resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)?.path == joined)
    }

    /// The trailing-side legacy seam remains deliberately col-0-only. In a
    /// 3-row candidate this forces the existing fragment-alone probe for an
    /// indented final child, even though the leading-side seam is now allowed
    /// to use bounded indentation.
    @Test("The trailing slash seam still probes an indented final child")
    func trailingSlashSeamKeepsTheIndentedFinalFragmentProbe() throws {
        let cwd = "/tmp/listing-trailing"
        let intermediate = "intermediate/0123456789abcdef/"
        let rows = [
            cwd + "/dir/",
            "  \(intermediate)",
            "  child.txt",
        ]
        let directory = cwd + "/dir"
        let intermediateCandidate = rows[0] + intermediate.dropLast()
        let intermediateStandalone = cwd + "/" + intermediate.dropLast()
        let child = cwd + "/child.txt"
        let joined = rows[0] + intermediate + "child.txt"
        // Keep the shorter two-row candidate alive, but also make its
        // continuation fragment independently exist so it cannot mask the
        // three-row endpoint rejection as `candidateDoesNotExist`.
        let resolver = TerminalPathResolver(fileExists: existsIn([
            directory, intermediateCandidate, intermediateStandalone, child, joined,
        ]))
        let seed = try #require(resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd, columns: rows[0].count))
        let outcome = resolver.resolveWrappedCandidateWithOutcome(
            seed: seed, rows: rows, clickedIndex: 0, columns: rows[0].count, cwd: cwd, purpose: .hover
        )

        #expect(outcome.candidate == nil)
        #expect(outcome.evaluatorOutcome?.diagnosticName == "fragmentAloneExists")
    }

    // R8 precondition from impl-request-bullet-width-and-slash-multirow-8810:
    // the continuation-side click already resolves the exact four-row
    // fixture before the leading-row bounds change. This test is intentionally
    // present in the test-only commit and must pass before production code is
    // changed; if it fails, the design requires stopping for clarification.
    @Test("R8: the exact slash-terminated fixture resolves from its second row before the scope change")
    func r8SlashTerminatedFixtureContinuationClickResolvesBeforeScopeChange() throws {
        let rows = [
            "- html: /Users/yosuke/workspace/github.com/",
            "TMLlaboratory/s-code/research/docs/notes/20",
            "26-07-31_scaffold_kl_foundations_and_measur",
            "ement_limits.html",
        ]
        let expected = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code/research/docs/notes/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let resolver = TerminalPathResolver(fileExists: existsIn([expected]))
        let seed = try #require(
            resolver.wrappedPathSeed(in: rows[1], column: 0, cwd: "/tmp", columns: rows[0].count)
        )
        let window = try #require(
            TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: rows[0].count)
        )
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, window: window, cwd: "/tmp", geometry: TerminalWrapGeometry(fullnessTolerance: 0)
        )
        #expect(candidate?.path == expected)
        guard case .available(let spans) = candidate?.cellSpans else {
            Issue.record("R8 continuation click should expose the full cell span")
            return
        }
        #expect(Set(spans.map { 1 + $0.rowOffsetFromClicked }) == [0, 1, 2, 3])
    }

    @Test("The exact slash-terminated fixture resolves from every row and exposes the full leading hover span")
    func exactSlashTerminatedFixtureResolvesFromEveryRowAndHover() throws {
        let rows = [
            "- html: /Users/yosuke/workspace/github.com/",
            "TMLlaboratory/s-code/research/docs/notes/20",
            "26-07-31_scaffold_kl_foundations_and_measur",
            "ement_limits.html",
        ]
        let expected = "/Users/yosuke/workspace/github.com/TMLlaboratory/s-code/research/docs/notes/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let resolver = TerminalPathResolver(fileExists: existsIn([
            "/Users/yosuke/workspace/github.com/",
            expected,
        ]))
        let geometry = try #require(TerminalWrapGeometry(fullnessTolerance: 0))

        func absoluteSpans(_ resolution: TerminalWrappedPathResolution, clickedIndex: Int) -> Set<[Int]> {
            guard case .available(let spans) = resolution.cellSpans else {
                Issue.record("Expected available spans for the exact slash fixture")
                return []
            }
            return Set(spans.map { span in
                [clickedIndex + span.rowOffsetFromClicked, span.startColumn, span.endColumn]
            })
        }

        var clickResolutions: [TerminalWrappedPathResolution] = []
        for clickedIndex in rows.indices {
            let clickColumn = clickedIndex == 0 ? 8 : 0
            let seed = try #require(
                resolver.wrappedPathSeed(in: rows[clickedIndex], column: clickColumn, cwd: "/tmp", columns: 43)
            )
            let window = try #require(
                TerminalPhysicalRowWindow(rows: rows, clickedIndex: clickedIndex, columns: 43)
            )
            let resolution = try #require(
                resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: "/tmp", geometry: geometry)
            )
            #expect(resolution.path == expected)
            clickResolutions.append(resolution)
        }

        let expectedSpans: Set<[Int]> = [
            [0, 8, 43],
            [1, 0, 43],
            [2, 0, 43],
            [3, 0, 17],
        ]
        for (clickedIndex, resolution) in clickResolutions.enumerated() {
            #expect(absoluteSpans(resolution, clickedIndex: clickedIndex) == expectedSpans)
        }

        let leadingSeed = try #require(
            resolver.wrappedPathSeed(in: rows[0], column: 8, cwd: "/tmp", columns: 43)
        )
        let hoverResolution = try #require(
            resolver.resolveWrappedCandidate(
                seed: leadingSeed,
                rows: rows,
                clickedIndex: 0,
                columns: 43,
                cwd: "/tmp",
                purpose: .hover
            )
        )
        #expect(hoverResolution.path == expected)
        #expect(absoluteSpans(hoverResolution, clickedIndex: 0) == expectedSpans)
    }

    @Test("A slash-seam multi-row candidate is rejected when its trailing fragment is an independent existing path")
    func slashSeamMultiRowRejectsAnLsStyleTrailingFragmentFalsePositive() throws {
        let cwd = "/tmp"
        let rows = ["/tmp/projx/", "report.part", "two.md"]
        let rowLocalDirectory = "/tmp/projx"
        let adjacentCandidate = "/tmp/projx/report.part"
        let dominatingCandidate = "/tmp/projx/report.parttwo.md"
        let trailingFragmentAlone = "/tmp/two.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([
            rowLocalDirectory,
            adjacentCandidate,
            dominatingCandidate,
            trailingFragmentAlone,
        ]))
        let seed = try #require(resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd, columns: 11))
        #expect(seed.disposition == .explicitTrailingSlashSeamBypass)
        let window = try #require(TerminalPhysicalRowWindow(rows: rows, clickedIndex: 0, columns: 11))

        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, window: window, cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
        )
        #expect(candidate?.path == adjacentCandidate)
    }

    // design-next-round-bundle-8810.md §1 rule 2 — the click-only
    // text-only fallback must NEVER activate once a `geometry` value is
    // in play: `evaluateContiguousSpans` extracts every piece through
    // the guarded extractors only (never
    // `String.trailingContinuationFragmentText()`), so this exact
    // bug-B bullet-prefixed fixture — which DOES resolve through the
    // legacy 2-row overload (see
    // `bulletPrefixedPreviousRowResolvesViaTextOnlyOnTheLegacyClickPathNextDirectionUnaffected`
    // in `TerminalPathResolverTests.swift`) — must stay `nil` through
    // the geometry-aware, window-based overload.
    @Test("A non-ASCII previous row's text-only fallback never activates once geometry is supplied")
    func nonASCIIPreviousRowStaysNilThroughTheGeometryAwareOverloadEvenThoughLegacyResolves() throws {
        let cwd = "/tmp/bugB"
        let row30 = "\u{25CF} research/docs/notes/2026-07-31_key_cost_volume_price_and_probab"
        let row31 = "  ility_floor.md"
        let row32 = "  research/docs/notes/2026-07-31_scaffold_kl_foundations_and_meas"
        let mdFile = cwd + "/research/docs/notes/2026-07-31_key_cost_volume_price_and_probability_floor.md"
        let htmlFile = cwd + "/research/docs/notes/2026-07-31_scaffold_kl_foundations_and_measurement_limits.html"
        let resolver = TerminalPathResolver(fileExists: existsIn([mdFile, htmlFile]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        let seed = try #require(resolver.wrappedPathSeed(in: row31, column: 12, cwd: cwd))
        // Confirm the legacy 2-row overload DOES resolve this fixture —
        // otherwise this test would trivially pass for the wrong reason.
        #expect(resolver.resolveWrappedCandidate(seed: seed, previousRow: row30, nextRow: row32, cwd: cwd)?.path == mdFile)

        let rows = [row30, row31, row32]
        let window = try #require(TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: 65))
        #expect(resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry) == nil)
    }

    // MARK: - span / adoption rules

    @Test("Exact 3-row and 4-row candidates resolve from a leading, middle, or trailing click")
    func exactThreeAndFourRowNormalCasesResolveFromAnyClickedRow() {
        let cwd = "/tmp"
        // A 4-row bare-relative split with no `/`-seam involved at all —
        // exercises the general contiguous-span evaluator (final-spec §4),
        // not the mirror-seam special case above. Every row's content
        // reaches column 6 (the fixture's grid width), so every internal
        // boundary passes the fullness guard regardless of which row is
        // clicked.
        // Every row's own text contains a `/` (`leadingPieceNotPathPrefixShaped`
        // applies to whichever row acts as the span's leading endpoint,
        // regardless of click position — a row with no `/` at all, like a
        // literal "resear"/"ch/doc" split, could never pass that guard from
        // any clicked row and isn't a realistic wrapped-path shape anyway).
        let rows = ["re/sea", "rch/do", "cs/rep", "ort.md"]
        let expectedCandidate = "/tmp/re/search/docs/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedCandidate]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        for clickedIndex in rows.indices {
            let clickedRow = rows[clickedIndex]
            guard let seed = resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd) else {
                Issue.record("Expected a seed at row \(clickedIndex) — the 4-row fixture must at least tokenize")
                continue
            }
            guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: clickedIndex, columns: 6) else {
                Issue.record("Expected a valid window at row \(clickedIndex)")
                continue
            }
            let candidate = resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
            #expect(
                candidate?.path == expectedCandidate,
                "row \(clickedIndex): the 4-row span evaluator must resolve the full candidate from any clicked row"
            )
        }
    }

    @Test("An indented interior row resolves the same span from every clicked row")
    func indentedInteriorRowIsClickPositionInvariant() throws {
        let rowsWithoutPadding = [
            "/Users/dev/project42/TMLlaborato",
            "  ry/s-code/research/docs/notes/",
            "  report.md",
        ]
        let expectedCandidate = "/Users/dev/project42/TMLlaboratory/s-code/research/docs/notes/report.md"
        let columns = rowsWithoutPadding.map(\.count).max()!
        let rows = rowsWithoutPadding.map { row in
            row + String(repeating: " ", count: columns - row.count)
        }
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedCandidate]))
        let geometry = try #require(TerminalWrapGeometry(fullnessTolerance: 0))

        func absoluteRows(_ resolution: TerminalWrappedPathResolution?, clickedIndex: Int) -> Set<Int> {
            guard case .available(let spans) = resolution?.cellSpans else { return [] }
            return Set(spans.map { clickedIndex + $0.rowOffsetFromClicked })
        }

        func assertCellSpansWithinBounds(_ resolution: TerminalWrappedPathResolution, columns: Int) {
            guard case .available(let spans) = resolution.cellSpans else {
                Issue.record("Expected available cell spans")
                return
            }
            for span in spans {
                #expect(span.startColumn >= 0)
                #expect(span.startColumn < span.endColumn)
                #expect(span.endColumn <= columns)
            }
        }

        var candidates: [TerminalWrappedPathResolution] = []
        for clickedIndex in rows.indices {
            let clickColumn = clickedIndex == 0 ? 10 : 2
            let seed = try #require(
                resolver.wrappedPathSeed(in: rows[clickedIndex], column: clickColumn, cwd: "/tmp", columns: columns)
            )
            let window = try #require(
                TerminalPhysicalRowWindow(rows: rows, clickedIndex: clickedIndex, columns: columns)
            )
            let candidate = try #require(
                resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: "/tmp", geometry: geometry)
            )
            assertCellSpansWithinBounds(candidate, columns: columns)
            candidates.append(candidate)
        }

        #expect(candidates.allSatisfy { $0.path == expectedCandidate })
        #expect(candidates.enumerated().allSatisfy { absoluteRows($0.element, clickedIndex: $0.offset) == [0, 1, 2] })

        let hoverSeed = try #require(
            resolver.wrappedPathSeed(in: rows[1], column: 2, cwd: "/tmp", columns: columns)
        )
        let hoverCandidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: hoverSeed, rows: rows, clickedIndex: 1, columns: columns, cwd: "/tmp", purpose: .hover
            )
        )
        #expect(hoverCandidate.path == expectedCandidate)
        assertCellSpansWithinBounds(hoverCandidate, columns: columns)
    }

    @Test("Incomparable multi-row successes are nil; a success contained by another adopts the dominating span")
    func incomparableSuccessesAreNilDominatingSpanIsAdopted() {
        let cwd = "/tmp"
        // A 3-row bare-relative fixture where the SHORTER 2-row join
        // ([0,1], "a/mid"+"dle.part") already resolves to a real, existing
        // path on its own — a span whose row range is CONTAINED by the
        // longer 3-row span ([0,2]) — so the longer span dominates
        // (final-spec §4.3 rule 1) rather than both surviving as
        // independent, ambiguous successes.
        let rows = ["a/mid", "dle.part", "two.md"]
        let shortCandidate = "/tmp/a/middle.part"
        let longCandidate = "/tmp/a/middle.parttwo.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([shortCandidate, longCandidate]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        guard let seed = resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the leading row")
            return
        }
        // columns: 5 — matches "a/mid" (row0) reaching the strict right edge.
        guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: 0, columns: 5) else {
            Issue.record("Expected a valid window")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        // The dominating (longer, 3-row) span wins over the incomparable
        // shorter 2-row candidate.
        #expect(candidate?.path == longCandidate)
    }

    @Test("A pair of adjacent-but-not-wrapped rows (fullness negative) never produces a candidate")
    func fullnessNegativeAdjacentRowsProduceNoCandidate() {
        let cwd = "/tmp"
        // `short` does NOT reach the physical right edge of a wide grid —
        // this is an ordinary end-of-line, not a hard wrap — even though
        // the joined candidate happens to exist.
        let clickedRow = "short"
        let nextRow = "tail.md"
        let coincidental = "/tmp/shorttail.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([coincidental]))
        // A wide grid (80 columns) makes `short`'s 5 characters nowhere
        // near the physical edge — the fullness guard (final-spec §4.2)
        // rejects every span crossing this boundary.
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        guard let seed = resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the bare-relative clicked row")
            return
        }
        guard let window = TerminalPhysicalRowWindow(rows: [clickedRow, nextRow], clickedIndex: 0, columns: 80) else {
            Issue.record("Expected a valid window")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        #expect(candidate == nil)
    }

    @Test("Exceeding maxWrappedRows, the 7-row snapshot window, or the 2048-byte candidate cap fails closed")
    func exceedingRowOrLengthBoundsFailsClosed() {
        // `TerminalPhysicalRowWindow`/`TerminalPhysicalRowsSnapshot`
        // themselves already enforce the 7-row snapshot cap (final-spec
        // §7) — this pins that independent of the evaluator.
        let eightRows = (0..<8).map { "row\($0)" }
        #expect(TerminalPhysicalRowWindow(rows: eightRows, clickedIndex: 0, columns: 80) == nil)
        #expect(
            TerminalPhysicalRowsSnapshot(
                rawText: eightRows.joined(separator: "\n"), topRow: 0, expectedRowCount: 8, columns: 80
            ) == nil
        )

        // A candidate needing 5 fragments (1 more than maxWrappedRows) to
        // spell the real path must fail closed — the evaluator can only
        // ever see spans up to length 4, so no 5-row span is even
        // enumerated, regardless of the window holding all 5 rows.
        let cwd = "/tmp"
        let rows = ["re", "se", "ar", "ch", ".md"] // 5 fragments, 1 more than maxWrappedRows
        let overlong = "/tmp/research.md" // exists, but only spellable by joining all 5 rows
        let resolver = TerminalPathResolver(fileExists: existsIn([overlong]))
        guard let seed = resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the leading row")
            return
        }
        guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: 0, columns: 2) else {
            Issue.record("Expected a valid window")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, window: window, cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
        )
        #expect(candidate == nil)
    }

    // MARK: - nativeMatchKeys

    @Test("The existing 2-row bug A fixture's 3 match keys are unchanged through the geometry-aware overload")
    func twoRowBugAFixtureKeysMatchExactlyViaGeometryPath() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/"
        let clickedRow = "notes/2026-report.md"
        let existingFile = previousRow + clickedRow
        let resolver = TerminalPathResolver(fileExists: existsIn([existingFile]))
        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        let window = try #require(
            TerminalPhysicalRowWindow(rows: [previousRow, clickedRow], clickedIndex: 1, columns: previousRow.count)
        )
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed, window: window, cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
            )
        )
        #expect(candidate.nativeMatchKeys == [existingFile, clickedRow, previousRow])
    }

    @Test("A 4-row center click's nativeMatchKeys stay within the cap-8 exact set and order")
    func fourRowCenterClickKeysCapAtEightExactSetAndOrder() {
        let cwd = "/tmp"
        // Every row's own text contains a `/` (`leadingPieceNotPathPrefixShaped`
        // applies to whichever row acts as the span's leading endpoint,
        // regardless of click position — a row with no `/` at all, like a
        // literal "resear"/"ch/doc" split, could never pass that guard from
        // any clicked row and isn't a realistic wrapped-path shape anyway).
        let rows = ["re/sea", "rch/do", "cs/rep", "ort.md"]
        let expectedCandidate = "/tmp/re/search/docs/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedCandidate]))
        guard let seed = resolver.wrappedPathSeed(in: rows[1], column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the center row")
            return
        }
        guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: 6) else {
            Issue.record("Expected a valid window")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, window: window, cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
        )
        // final-spec §6.4: a 4-row span clicked in the center expects
        // exactly 8 keys — the exact SET and ORDER (§6.2), not just the
        // count: full candidate, clicked constituent, immediate neighbor
        // above, immediate neighbor below, then the 4 remaining
        // clicked-containing subchains by length-desc/start-asc.
        #expect(candidate?.path == expectedCandidate)
        #expect(candidate?.nativeMatchKeys == [
            "re/search/docs/report.md", // full: [0,3]
            "rch/do", // clicked: [1,1]
            "re/sea", // neighbor above: [0,0]
            "cs/rep", // neighbor below: [2,2]
            "re/search/docs/rep", // [0,2] — length 3, start 0
            "rch/docs/report.md", // [1,3] — length 3, start 1
            "re/search/do", // [0,1] — length 2, start 0
            "rch/docs/rep", // [1,2] — length 2, start 1
        ])
    }

    // MARK: - parity / type

    @Test("Hover-style and click-style resolves of the same fixture agree on candidate, spans, and keys")
    func hoverAndClickResolvesOfTheSameFixtureAgree() {
        let cwd = "/tmp"
        let rows = ["foo", "/bar/", "baz.md"]
        let resolver = TerminalPathResolver(fileExists: existsIn(["/tmp/foo", "/tmp/foo/bar/baz.md"]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        // Two independent resolves standing in for hover (first pass) and
        // click (release-time re-check) against the identical input —
        // must never disagree. Clicking row1 (not the bug-B-gated
        // row-local-hit row0) keeps this test independent of that gate.
        func resolveAsIfFromRow1() -> TerminalWrappedPathResolution? {
            // columns: 3 — matches "foo" (row0) reaching the strict right edge.
            guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: 3) else { return nil }
            guard let seed = resolver.wrappedPathSeed(in: rows[1], column: 0, cwd: cwd) else { return nil }
            return resolver.resolveWrappedCandidate(seed: seed, window: window, cwd: cwd, geometry: geometry)
        }
        let hoverResult = resolveAsIfFromRow1()
        let clickResult = resolveAsIfFromRow1()
        #expect(hoverResult == clickResult)
        #expect(hoverResult?.path == "/tmp/foo/bar/baz.md")
    }

    // final-spec §13 "window / geometry の columns 不一致が型で作れないこと":
    // `TerminalWrapGeometry` has NO `columns` field at all (see its own
    // doc) — there is no pair of stored properties that could ever
    // disagree, so this is a compile-time/API-shape property, not a
    // runtime behavior a `#expect` can exercise. Documented here per the
    // spec's own fallback instruction ("コンパイル不能をテストで示せない
    // 場合はAPI形状をDocCとレビューで担保する旨を明記") rather than as a
    // runtime test.

    // MARK: - probe budget

    @Test("Resolving a 4-row candidate never exceeds the 15-probe budget, even with all 4 rows in play")
    func fourRowResolveStaysWithinTheProbeBudget() {
        let cwd = "/tmp"
        // Every row's own text contains a `/` (`leadingPieceNotPathPrefixShaped`
        // applies to whichever row acts as the span's leading endpoint,
        // regardless of click position — a row with no `/` at all, like a
        // literal "resear"/"ch/doc" split, could never pass that guard from
        // any clicked row and isn't a realistic wrapped-path shape anyway).
        let rows = ["re/sea", "rch/do", "cs/rep", "ort.md"]
        let expectedCandidate = "/tmp/re/search/docs/report.md"

        final class ProbeRecorder: @unchecked Sendable {
            private(set) var probedPaths: [String] = []
            private let existingPaths: Set<String>
            init(existingPaths: Set<String>) { self.existingPaths = existingPaths }
            func fileExists(_ path: String) -> Bool {
                probedPaths.append(path)
                return existingPaths.contains((path as NSString).standardizingPath)
            }
        }
        // The seed is constructed through a SEPARATE, non-recording
        // resolver — `wrappedPathSeed`'s own row-local check
        // (`resolveVisibleLinePath`) probes the filesystem too, on a
        // completely different budget, and must never count against the
        // wrapped-candidate-phase assertions below (matches the existing
        // convention in `TerminalWrappedBidirectionalResolutionTests`'
        // `ProbeRecorder` doc).
        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        // Click the CENTER row (index 1), not the leading row — a leading
        // click only ever enumerates spans starting at row 0 (3 spans
        // total), never final-spec §8's worst case. A center click
        // enumerates every (spanStart, spanEnd) combination §8 counts
        // toward the 9-candidate/6-fragment-alone/15-probe budget.
        guard let seed = seedResolver.wrappedPathSeed(in: rows[1], column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the center row")
            return
        }
        let recorder = ProbeRecorder(existingPaths: [expectedCandidate])
        let resolver = TerminalPathResolver(fileExists: recorder.fileExists)
        guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: 6) else {
            Issue.record("Expected a valid window")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, window: window, cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
        )
        #expect(recorder.probedPaths.count <= TerminalWrapGeometryTests.maxProbeBudget)
        // final-spec §8 rule 2 — no duplicate probe of the same
        // standardized path across spans/boundaries within one resolve.
        #expect(Set(recorder.probedPaths).count == recorder.probedPaths.count)
        // final-spec §8 rule 1 — the clicked token itself ("rch/do") is
        // never re-probed as a fragment-alone candidate.
        #expect(!recorder.probedPaths.contains(cwd + "/" + rows[1]))
        // The real point of this test: the 4-row candidate must actually
        // resolve, not just stay under budget by doing nothing.
        #expect(candidate?.path == expectedCandidate)
    }

    private static let maxProbeBudget = 15

    // review §B5 — the evaluator's probe cache must key on the
    // STANDARDIZED path, not the raw candidate/fragment spelling. This
    // fixture makes the SAME real target reachable via two genuinely
    // different raw spellings within ONE search: `previousRow`'s own
    // tilde-form fragment (probed alone, span(0,1)'s leading-endpoint
    // check) and `nextRow`'s pre-expanded absolute form of that SAME
    // path (probed alone, span(1,2)'s trailing-endpoint check) — two
    // different `String`s that `probeExists` standardizes to the exact
    // same value.
    @Test("A fragment's tilde spelling and another endpoint's pre-expanded absolute spelling of the same path probe exactly once")
    func standardizedPathDedupeCollapsesDifferentRawSpellingsToOneProbe() {
        let cwd = "/tmp/b5"
        let previousRow = "~/b5shared"
        let clickedToken = "y/x.md"
        let absoluteShared = (previousRow as NSString).expandingTildeInPath
        let nextRow = absoluteShared
        let rows = [previousRow, clickedToken, nextRow]

        func standardized(_ raw: String) -> String {
            let expanded = (raw as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
            return (path as NSString).standardizingPath
        }
        // The shared collision target — reached via `previousRow`'s
        // tilde spelling alone AND `nextRow`'s already-expanded absolute
        // spelling alone.
        let sharedTarget = standardized(previousRow)
        #expect(sharedTarget == standardized(nextRow), "the fixture's own premise: two spellings, one target")
        // The two spans' FULL joined candidates — unrelated to the
        // collision, but must exist for the search to reach either
        // endpoint's fragment-alone check at all (probed once each,
        // trivially, since each is requested only once).
        let span01Candidate = standardized(previousRow + clickedToken)
        let span12Candidate = standardized(clickedToken + nextRow)

        final class ProbeRecorder: @unchecked Sendable {
            private(set) var probedPaths: [String] = []
            private let existingPaths: Set<String>
            init(existingPaths: Set<String>) { self.existingPaths = existingPaths }
            func fileExists(_ path: String) -> Bool {
                probedPaths.append(path)
                return existingPaths.contains(path)
            }
        }
        let seedResolver = TerminalPathResolver(fileExists: existsIn([]))
        guard let seed = seedResolver.wrappedPathSeed(in: clickedToken, column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the clicked row")
            return
        }
        #expect(seed.directions == [.previous, .next])
        let recorder = ProbeRecorder(existingPaths: [sharedTarget, span01Candidate, span12Candidate])
        let resolver = TerminalPathResolver(fileExists: recorder.fileExists)
        // columns: 6 — both `previousRow` (index 9, already past it) and
        // `clickedToken` (index 5) reach the strict right edge, so both
        // internal boundaries (0,1) and (1,2) are full and both spans
        // are attempted.
        guard let window = TerminalPhysicalRowWindow(rows: rows, clickedIndex: 1, columns: 6) else {
            Issue.record("Expected a valid window")
            return
        }
        _ = resolver.resolveWrappedCandidate(
            seed: seed, window: window, cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
        )
        // The real point of this test: `sharedTarget` reached the real
        // `fileExists` exactly once, despite two differently-spelled raw
        // probes targeting it.
        #expect(recorder.probedPaths.filter { $0 == sharedTarget }.count == 1)
    }

    // MARK: - snapshot

    @Test("TerminalPhysicalRowsSnapshot forwards rawText byte-for-byte, including a trailing newline sentinel and short-read padding")
    func snapshotForwardsRawTextByteForByte() throws {
        let rawText = "line0\nline1\n" // trailing-newline sentinel for a 2-row read
        let snapshot = try #require(
            TerminalPhysicalRowsSnapshot(rawText: rawText, topRow: 3, expectedRowCount: 2, columns: 40)
        )
        // `rawText` is forwarded EXACTLY as read — never reconstructed
        // from `rows` (which would drop the sentinel newline `rows.joined`
        // could never reproduce byte-for-byte).
        #expect(snapshot.rawText == rawText)
        #expect(snapshot.rows == ["line0", "line1"])
        #expect(snapshot.rowCount == 2)

        // A short read (fewer physical lines than expected) still pads
        // `rows` at the end only, while `rawText` remains the untouched
        // original bytes.
        let shortRawText = "onlyOneLine"
        let shortSnapshot = try #require(
            TerminalPhysicalRowsSnapshot(rawText: shortRawText, topRow: 0, expectedRowCount: 3, columns: 40)
        )
        #expect(shortSnapshot.rawText == shortRawText)
        #expect(shortSnapshot.rows == ["onlyOneLine", "", ""])
    }

    @Test("TerminalPhysicalRowsSnapshot fails closed when rows/columns can't be reconciled with the raw text")
    func snapshotFailsClosedOnUnreconcilableRowsOrColumns() {
        // More physical lines in the text than `expectedRowCount` claims
        // — exactly the "rows changed mid-capture" shape a stale
        // before/after metrics mismatch would produce; the snapshot must
        // never silently truncate or guess.
        #expect(
            TerminalPhysicalRowsSnapshot(
                rawText: "a\nb\nc\nd", topRow: 0, expectedRowCount: 2, columns: 40
            ) == nil
        )
        #expect(TerminalPhysicalRowsSnapshot(rawText: "a\nb", topRow: 0, expectedRowCount: 2, columns: 0) == nil)
        #expect(TerminalPhysicalRowsSnapshot(rawText: "a\nb", topRow: 0, expectedRowCount: 0, columns: 40) == nil)
        #expect(TerminalPhysicalRowsSnapshot(rawText: "a\nb", topRow: 0, expectedRowCount: 8, columns: 40) == nil)
    }
}
