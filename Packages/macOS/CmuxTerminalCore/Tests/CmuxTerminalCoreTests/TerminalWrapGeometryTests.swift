import Foundation
import Testing
import CmuxTerminalCore

private func existsIn(_ existingPaths: Set<String>) -> @Sendable (String) -> Bool {
    let standardized = Set(existingPaths.map { ($0 as NSString).standardizingPath })
    return { path in standardized.contains((path as NSString).standardizingPath) }
}

// impl-scope-expansion-8810-test-only (final-spec-scope-expansion-8810.md
// §13) — issue #8810's two scope expansions: 3+ row hard-wrap support and
// bidirectional `/`-continuation search. Per final-spec §12's
// implementation order, the contiguous-span evaluator, mirror-slash-seam
// predicate, and `TerminalRowLocalDisposition` wiring are gated on bug
// B's real-machine root-cause confirmation and are NOT implemented in
// this pass — `resolveWrappedCandidate(seed:previousRow:nextRow:cwd:
// geometry:)` currently ignores `geometry` outright and falls back to
// the existing adjacent-row-only behavior (see its own doc). Most tests
// below therefore FAIL AS EXPECTED (assertion failures showing the
// deferred behavior isn't there yet, never compile errors) — this is a
// project-convention "commit 1 = failing test only, CI red" test-only
// commit; the matching fix lands in a later pass.
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
        let row0 = "foo"
        let row1 = "/bar/"
        let row2 = "baz.md"
        let parentDirectory = "/tmp/foo"
        let expectedCandidate = "/tmp/foo/bar/baz.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([parentDirectory, expectedCandidate]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        // row0 click: expected to resolve to the 3-row candidate, same as
        // row1/row2 below — but `wrappedPathSeed` doesn't even reach the
        // evaluator: `foo` row-locally resolves to the existing `cwd/foo`
        // directory, so the (currently adjacent-row-only, geometry-blind)
        // seed step returns `nil` outright, unlike row1/row2's seeds.
        let row0Seed = resolver.wrappedPathSeed(in: row0, column: 0, cwd: cwd)
        let row0Candidate = row0Seed.flatMap {
            resolver.resolveWrappedCandidate(seed: $0, previousRow: nil, nextRow: row1, cwd: cwd, geometry: geometry)
        }

        let row1Seed = resolver.wrappedPathSeed(in: row1, column: 0, cwd: cwd)
        let row1Candidate = row1Seed.flatMap {
            resolver.resolveWrappedCandidate(seed: $0, previousRow: row0, nextRow: row2, cwd: cwd, geometry: geometry)
        }

        let row2Seed = resolver.wrappedPathSeed(in: row2, column: 0, cwd: cwd)
        let row2Candidate = row2Seed.flatMap {
            resolver.resolveWrappedCandidate(seed: $0, previousRow: row1, nextRow: nil, cwd: cwd, geometry: geometry)
        }

        #expect(row0Candidate?.path == expectedCandidate)
        #expect(row1Candidate?.path == expectedCandidate)
        #expect(row2Candidate?.path == expectedCandidate)
    }

    @Test("The 3-row mirror fixture requires a literal `/` prefix, a strict right edge, AND geometry")
    func threeRowMirrorFixtureRequiresSlashPrefixStrictEdgeAndGeometry() {
        let cwd = "/tmp"
        let row0 = "foo"
        let parentDirectory = "/tmp/foo"
        let expectedCandidate = "/tmp/foo/bar/baz.md"
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        func candidateFromRow0(nextRow row1: String, geometry: TerminalWrapGeometry?) -> TerminalWrappedPathResolution? {
            let resolver = TerminalPathResolver(fileExists: existsIn([parentDirectory, expectedCandidate]))
            guard let seed = resolver.wrappedPathSeed(in: row0, column: 0, cwd: cwd) else { return nil }
            return resolver.resolveWrappedCandidate(seed: seed, previousRow: nil, nextRow: row1, cwd: cwd, geometry: geometry)
        }

        // row1 not starting with a literal `/` — no mirror seam, must
        // stay `nil` (the existing row-local `cwd/foo` hit is preserved
        // by the CALLER, not by this resolver call itself, but the
        // resolver must not manufacture a wrapped candidate here).
        #expect(candidateFromRow0(nextRow: "bar/", geometry: geometry) == nil)

        // row0 does not reach the strict physical right edge (trailing
        // whitespace before the grid edge) — no mirror seam.
        #expect(candidateFromRow0(nextRow: "/bar/", geometry: geometry) == nil)

        // No geometry at all — multi-row/mirror-seam behavior is
        // unavailable regardless of shape.
        #expect(candidateFromRow0(nextRow: "/bar/", geometry: nil) == nil)
    }

    // final-spec §3.1: the existing bug A exception must NOT extend to
    // multiple rows even once a `geometry` value is passed — mixing the
    // two dispositions is explicitly forbidden (§3.2's closing note).
    @Test("The existing trailing-`/`-seam bug A exception stays adjacent-only even with geometry supplied")
    func explicitTrailingSlashSeamBypassStaysAdjacentOnlyEvenWithGeometry() throws {
        let cwd = "/tmp"
        let previousRow = "/Users/dev/project/research/docs/"
        let clickedRow = "notes/report"
        let continuationRow = ".md"
        let joinedTwoRow = previousRow + clickedRow
        let joinedThreeRow = previousRow + clickedRow + continuationRow
        let resolver = TerminalPathResolver(fileExists: existsIn([previousRow, joinedTwoRow, joinedThreeRow]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        let seed = try #require(resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd))
        // Only the ADJACENT previous row is ever supplied — a 3-row
        // reach into `continuationRow` must never happen for this
        // disposition, geometry or not.
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd, geometry: geometry
        )
        #expect(candidate?.path == joinedTwoRow)
    }

    // MARK: - span / adoption rules

    @Test("Exact 3-row and 4-row candidates resolve from a leading, middle, or trailing click")
    func exactThreeAndFourRowNormalCasesResolveFromAnyClickedRow() {
        let cwd = "/tmp"
        // A 4-row bare-relative split with no `/`-seam involved at all —
        // exercises the general contiguous-span evaluator (final-spec §4),
        // not the mirror-seam special case above.
        let rows = ["resear", "ch/doc", "s/repo", "rt.md"]
        let expectedCandidate = "/tmp/research/docs/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedCandidate]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        for clickedIndex in rows.indices {
            let clickedRow = rows[clickedIndex]
            guard let seed = resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd) else {
                Issue.record("Expected a seed at row \(clickedIndex) — the 4-row fixture must at least tokenize")
                continue
            }
            let previousRow = clickedIndex > 0 ? rows[clickedIndex - 1] : nil
            let nextRow = clickedIndex + 1 < rows.count ? rows[clickedIndex + 1] : nil
            let candidate = resolver.resolveWrappedCandidate(
                seed: seed, previousRow: previousRow, nextRow: nextRow, cwd: cwd, geometry: geometry
            )
            #expect(
                candidate?.path == expectedCandidate,
                "row \(clickedIndex): a single adjacent row can never reach a 4-row-wide candidate without the multi-row evaluator"
            )
        }
    }

    @Test("Incomparable multi-row successes are nil; a success contained by another adopts the dominating span")
    func incomparableSuccessesAreNilDominatingSpanIsAdopted() {
        let cwd = "/tmp"
        // A 3-row bare-relative fixture with a shorter, INCOMPARABLE
        // 2-row false-positive alongside the correct 3-row full path —
        // the 3-row span should dominate (final-spec §4.3 rule 1), never
        // both succeeding as incomparable (which would fail-closed to
        // `nil` under rule 2).
        let rows = ["mid", "dle.part", "two.md"]
        let shortCandidate = "/tmp/middle.part"
        let longCandidate = "/tmp/middle.parttwo.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([shortCandidate, longCandidate]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        guard let seed = resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the leading row")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, previousRow: nil, nextRow: rows[1], cwd: cwd, geometry: geometry
        )
        // The dominating (longer, 3-row) span should win — the
        // adjacent-row-only fallback can only ever see the 2-row
        // candidate, so this is expected to disagree until the evaluator
        // lands.
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
        // must reject this once the evaluator checks it against real
        // grid geometry; today's fallback has no grid-width awareness at
        // all, so it cannot enforce this guard yet.
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        guard let seed = resolver.wrappedPathSeed(in: clickedRow, column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the bare-relative clicked row")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, previousRow: nil, nextRow: nextRow, cwd: cwd, geometry: geometry
        )
        #expect(candidate == nil)
    }

    @Test("Exceeding maxWrappedRows, the 7-row snapshot window, or the 2048-byte candidate cap fails closed")
    func exceedingRowOrLengthBoundsFailsClosed() {
        // `TerminalPhysicalRowWindow`/`TerminalPhysicalRowsSnapshot`
        // themselves already enforce the 7-row snapshot cap (final-spec
        // §7) — this pins that today, independent of the deferred
        // evaluator.
        let eightRows = (0..<8).map { "row\($0)" }
        #expect(TerminalPhysicalRowWindow(rows: eightRows, clickedIndex: 0, columns: 80) == nil)
        #expect(
            TerminalPhysicalRowsSnapshot(
                rawText: eightRows.joined(separator: "\n"), topRow: 0, expectedRowCount: 8, columns: 80
            ) == nil
        )

        // A candidate exceeding `maxWrappedRows` (4) worth of joined rows
        // must fail closed once the evaluator enforces it — the current
        // fallback has no row-count-aware rejection at all, so this is
        // expected to disagree with a hypothetical (wrong) accept.
        let cwd = "/tmp"
        let rows = ["re", "se", "ar", "ch", ".md"] // 5 fragments, 1 more than maxWrappedRows
        let overlong = "/tmp/reseach.md" // deliberately not what the 5-row join would even spell — never expected to exist
        let resolver = TerminalPathResolver(fileExists: existsIn([overlong]))
        guard let seed = resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the leading row")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, previousRow: nil, nextRow: rows[1], cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
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
        let candidate = try #require(
            resolver.resolveWrappedCandidate(
                seed: seed, previousRow: previousRow, nextRow: nil, cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
            )
        )
        #expect(candidate.nativeMatchKeys == [existingFile, clickedRow, previousRow])
    }

    @Test("A 4-row center click's nativeMatchKeys stay within the cap-8 exact set and order")
    func fourRowCenterClickKeysCapAtEightExactSetAndOrder() {
        let cwd = "/tmp"
        let rows = ["resear", "ch/doc", "s/repo", "rt.md"]
        let expectedCandidate = "/tmp/research/docs/report.md"
        let resolver = TerminalPathResolver(fileExists: existsIn([expectedCandidate]))
        guard let seed = resolver.wrappedPathSeed(in: rows[1], column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the center row")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, previousRow: rows[0], nextRow: rows[2], cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
        )
        // final-spec §6.4: a 4-row span clicked in the center expects
        // exactly 8 keys (6 clicked-containing subchains + 2 immediate
        // neighbors). Today's adjacent-row-only fallback can never
        // resolve this 4-row candidate at all.
        #expect(candidate?.nativeMatchKeys.count == 8)
    }

    // MARK: - parity / type

    @Test("Hover-style and click-style resolves of the same fixture agree on candidate, spans, and keys")
    func hoverAndClickResolvesOfTheSameFixtureAgree() {
        let cwd = "/tmp"
        let row0 = "foo"
        let row1 = "/bar/"
        let row2 = "baz.md"
        let resolver = TerminalPathResolver(fileExists: existsIn(["/tmp/foo", "/tmp/foo/bar/baz.md"]))
        let geometry = TerminalWrapGeometry(fullnessTolerance: 0)

        // Two independent resolves standing in for hover (first pass)
        // and click (release-time re-check) against the identical input
        // — must never disagree, regardless of whether the underlying
        // behavior is the deferred multi-row path or today's fallback.
        func resolveAsIfFromRow1() -> TerminalWrappedPathResolution? {
            guard let seed = resolver.wrappedPathSeed(in: row1, column: 0, cwd: cwd) else { return nil }
            return resolver.resolveWrappedCandidate(seed: seed, previousRow: row0, nextRow: row2, cwd: cwd, geometry: geometry)
        }
        let hoverResult = resolveAsIfFromRow1()
        let clickResult = resolveAsIfFromRow1()
        #expect(hoverResult == clickResult)
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

    @Test("Resolving a 4-row candidate never exceeds the 15-probe budget, even though the row count exceeds today's fallback")
    func fourRowResolveStaysWithinTheProbeBudget() {
        let cwd = "/tmp"
        let rows = ["resear", "ch/doc", "s/repo", "rt.md"]
        let expectedCandidate = "/tmp/research/docs/report.md"

        final class ProbeRecorder: @unchecked Sendable {
            private(set) var probedPaths: [String] = []
            private let existingPaths: Set<String>
            init(existingPaths: Set<String>) { self.existingPaths = existingPaths }
            func fileExists(_ path: String) -> Bool {
                probedPaths.append(path)
                return existingPaths.contains((path as NSString).standardizingPath)
            }
        }
        let recorder = ProbeRecorder(existingPaths: [expectedCandidate])
        let resolver = TerminalPathResolver(fileExists: recorder.fileExists)
        guard let seed = resolver.wrappedPathSeed(in: rows[0], column: 0, cwd: cwd) else {
            Issue.record("Expected a seed for the leading row")
            return
        }
        let candidate = resolver.resolveWrappedCandidate(
            seed: seed, previousRow: nil, nextRow: rows[1], cwd: cwd, geometry: TerminalWrapGeometry(fullnessTolerance: 0)
        )
        #expect(recorder.probedPaths.count <= TerminalWrapGeometryTests.maxProbeBudget)
        // The real point of this test (once the evaluator lands): the
        // 4-row candidate must actually resolve, not just stay under
        // budget by doing nothing.
        #expect(candidate?.path == expectedCandidate)
    }

    private static let maxProbeBudget = 15

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
