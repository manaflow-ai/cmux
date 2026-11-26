import Testing

@testable import CmuxMobileChanges

@Suite struct DiffRowSnapshotTests {
    @Test func flattensHunksIntoOrderedRowsWithHeaderGaps() {
        let diff = """
        diff --git a/Sources/Foo.swift b/Sources/Foo.swift
        index 1111111..2222222 100644
        --- a/Sources/Foo.swift
        +++ b/Sources/Foo.swift
        @@ -1,3 +1,4 @@
         import Foundation
        -let old = 1
        +let value = 2
        +let extra = 3
         print(value)
        @@ -10,2 +11,2 @@ final class Widget {
        -    func oldName() {}
        +    func newName() {}
         }
        """
        let document = UnifiedDiffParser().parse(diff)

        let rows = DiffRowSnapshot.rows(for: document)

        // One row per document line (headers included), in wire order.
        #expect(rows.count == document.lines.count)
        #expect(rows.map(\.id) == ["h:0", "l:0:0", "l:0:1", "l:0:2", "l:0:3", "l:0:4", "h:1", "l:1:0", "l:1:1", "l:1:2"])
        #expect(rows[0].line == document.hunks[0].header)
        #expect(rows[0].leadingHunkGap == false)
        let secondHeaderIndex = document.hunks[0].lines.count + 1
        #expect(rows[secondHeaderIndex].line == document.hunks[1].header)
        #expect(rows[secondHeaderIndex].leadingHunkGap == true)
        // Only later hunk headers carry the gap.
        #expect(rows.filter(\.leadingHunkGap).count == document.hunks.count - 1)
        // Every row carries its own hunk's copy text.
        #expect(rows[1].hunkCopyText == document.hunks[0].copyText)
        #expect(rows.last?.hunkCopyText == document.hunks[1].copyText)
    }

    @Test func parsingWorkerPublishesFontIndependentRowsAndMaximumLineNumber() async {
        let presentation = await UnifiedDiffParser().parsePresentationOffMain(
            "@@ -9 +1234 @@\n-old\n+new",
            fileKind: .modified
        )

        #expect(presentation.rows.compactMap(\.line).count == presentation.document.lines.count)
        #expect(presentation.maximumLineNumber == 1_234)
    }

    @Test func derivesLeadingInnerAndUnresolvedTrailingGaps() {
        let document = gapFixtureDocument()

        let gaps = DiffGap.gaps(for: document, currentFileLineCount: nil)

        #expect(gaps.count == 3)
        #expect(gaps[0].placement == .leading)
        #expect(gaps[0].newLineRange == 1..<11)
        #expect(gaps[1].placement == .inner)
        #expect(gaps[1].newLineRange == 16..<33)
        #expect(gaps[2].placement == .trailing)
        #expect(gaps[2].newLineRange == nil)
    }

    @Test func expandsOneHundredLinesThenConsumesAShortRemainingRun() {
        let gap = DiffGap(
            id: 1,
            placement: .inner,
            newLineRange: 1..<221,
            oldLineOffset: 0
        )
        var state = DiffExpansionState()

        state.reveal(in: gap, direction: .down)
        #expect(state.revealedRanges(for: gap.id) == [1..<101])
        #expect(state.hiddenRanges(in: gap) == [101..<221])

        state.reveal(in: gap, direction: .up)
        #expect(state.revealedRanges(for: gap.id) == [1..<221])
        #expect(state.hiddenRanges(in: gap).isEmpty)
    }

    @Test func rapidStaleRevealIntentsAccumulateBeforeProjection() {
        let gap = DiffGap(
            id: 1,
            placement: .inner,
            newLineRange: 1..<351,
            oldLineOffset: 0
        )
        let staleHiddenRange = 1..<351
        var state = DiffExpansionState()

        state.reveal(
            in: gap,
            direction: .down,
            preferredHiddenRange: staleHiddenRange
        )
        state.reveal(
            in: gap,
            direction: .down,
            preferredHiddenRange: staleHiddenRange
        )

        #expect(state.revealedRanges(for: gap.id) == [1..<201])
        #expect(state.hiddenRanges(in: gap) == [201..<351])
    }

    @Test func cancelledExpansionProjectionStopsBeforePublishingRows() async {
        let document = gapFixtureDocument()
        let result = await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await FileDiffPresentation.prepareOffMainCancellable(
                document: document,
                expansionState: DiffExpansionState(),
                currentFileLines: (1...50).map { "line \($0)" },
                fileKind: .modified
            )
        }.value

        #expect(result == nil)
    }

    @Test func expansionFromBothEdgesKeepsCorrectOldAndNewGutters() throws {
        let document = gapFixtureDocument()
        let lines = (1...50).map { "line \($0)" }
        let gap = try #require(DiffGap.gaps(
            for: document,
            currentFileLineCount: lines.count
        ).first(where: { $0.placement == .inner }))
        var state = DiffExpansionState()

        state.reveal(in: gap, direction: .down)
        state.reveal(in: gap, direction: .up)
        let rows = DiffRowSnapshot.rows(
            for: document,
            expansionState: state,
            currentFileLines: lines,
            fileKind: .modified
        )
        let contextLines = rows.compactMap { row -> DiffLine? in
            guard case .line(let line, _) = row.content,
                  line.kind == .context,
                  (16..<33).contains(line.newNumber ?? 0) else { return nil }
            return line
        }

        #expect(contextLines.count == 17)
        #expect(contextLines.first?.oldNumber == 14)
        #expect(contextLines.first?.newNumber == 16)
        #expect(contextLines.last?.oldNumber == 30)
        #expect(contextLines.last?.newNumber == 32)
        #expect(contextLines.first?.text == "line 16")
        #expect(contextLines.last?.text == "line 32")
    }

    @Test func fullyRevealedGapProjectsOnlyPerLineContextRows() throws {
        let document = gapFixtureDocument()
        let lines = (1...50).map { "line \($0)" }
        let gap = try #require(DiffGap.gaps(
            for: document,
            currentFileLineCount: lines.count
        ).first(where: { $0.placement == .inner }))
        var state = DiffExpansionState()
        state.reveal(in: gap, direction: .down)

        let rows = DiffRowSnapshot.rows(
            for: document,
            expansionState: state,
            currentFileLines: lines,
            fileKind: .modified
        )
        let gapRows = rows.filter { row in
            row.id.hasPrefix("g:\(gap.id):") || row.id.hasPrefix("c:\(gap.id):")
        }

        #expect(gapRows.count == 17)
        #expect(gapRows.allSatisfy { row in
            guard case .line(let line, _) = row.content else { return false }
            return line.kind == .context
        })
    }

    @Test func trailingGapResolvesAfterCurrentFileLineCountArrives() throws {
        let document = gapFixtureDocument()
        let unresolved = try #require(DiffGap.gaps(
            for: document,
            currentFileLineCount: nil
        ).last)
        let resolved = try #require(DiffGap.gaps(
            for: document,
            currentFileLineCount: 40
        ).last)

        #expect(unresolved.placement == .trailing)
        #expect(unresolved.newLineRange == nil)
        #expect(resolved.placement == .trailing)
        #expect(resolved.newLineRange == 34..<41)

        let unresolvedRows = DiffRowSnapshot.rows(
            for: document,
            expansionState: DiffExpansionState(),
            currentFileLines: nil,
            fileKind: .modified
        )
        let resolvedRows = DiffRowSnapshot.rows(
            for: document,
            expansionState: DiffExpansionState(),
            currentFileLines: (1...40).map { "line \($0)" },
            fileKind: .modified
        )
        let unresolvedExpander = try #require(unresolvedRows.compactMap { row -> DiffExpanderSnapshot? in
            guard case .expander(let snapshot) = row.content,
                  snapshot.gap.placement == .trailing else { return nil }
            return snapshot
        }.first)
        let resolvedExpander = try #require(resolvedRows.compactMap { row -> DiffExpanderSnapshot? in
            guard case .expander(let snapshot) = row.content,
                  snapshot.gap.placement == .trailing else { return nil }
            return snapshot
        }.first)

        #expect(unresolvedExpander.hiddenNewLineRange == nil)
        #expect(resolvedExpander.hiddenNewLineRange == 34..<41)
        #expect(resolvedExpander.expansionLineCount == 7)
    }

    @Test func eofCoveringDiffDropsTrailingExpanderOnceLinesArrive() {
        // An added file's single hunk spans the whole file, so the trailing
        // gap is empty once the current line count is known. The page must
        // stop rendering the expander then; before the count arrives the
        // unresolved band is still projected.
        let document = FileDiffDocument(
            hunks: [hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 5)],
            truncated: false,
            isBinary: false
        )
        let lines = (1...5).map { "line \($0)" }
        let trailingExpanders = { (currentFileLines: [String]?) in
            DiffRowSnapshot.rows(
                for: document,
                expansionState: DiffExpansionState(),
                currentFileLines: currentFileLines,
                fileKind: .added
            ).filter { row in
                guard case .expander(let snapshot) = row.content else { return false }
                return snapshot.gap.placement == .trailing
            }.count
        }

        #expect(trailingExpanders(nil) == 1)
        #expect(trailingExpanders(lines) == 0)
    }

    @Test func truncatedDocumentProjectsNoTrailingExpander() {
        let document = gapFixtureDocument(truncated: true)
        let rows = DiffRowSnapshot.rows(
            for: document,
            expansionState: DiffExpansionState(),
            currentFileLines: (1...50).map { "line \($0)" },
            fileKind: .modified
        )
        let placements = rows.compactMap { row -> DiffGap.Placement? in
            guard case .expander(let snapshot) = row.content else { return nil }
            return snapshot.gap.placement
        }

        #expect(placements.contains(.leading))
        #expect(placements.contains(.inner))
        #expect(!placements.contains(.trailing))
    }

    @Test func unifiedButtonOnlyWhenOneTapRevealsTheWholeRun() {
        let gap = DiffGap(id: 1, placement: .inner, newLineRange: 1..<200, oldLineOffset: 0)
        let short = DiffExpanderSnapshot(gap: gap, hiddenNewLineRange: 1..<121)
        let long = DiffExpanderSnapshot(gap: gap, hiddenNewLineRange: 1..<122)
        let unresolved = DiffExpanderSnapshot(gap: gap, hiddenNewLineRange: nil)

        #expect(short.revealsCompletely)
        #expect(!long.revealsCompletely)
        #expect(!unresolved.revealsCompletely)
    }

    @Test func deletedAndBinaryDocumentsNeverProjectExpanders() {
        let textDocument = gapFixtureDocument()
        let binaryDocument = FileDiffDocument(hunks: textDocument.hunks, truncated: false, isBinary: true)
        let lines = (1...50).map { "line \($0)" }

        let deletedRows = DiffRowSnapshot.rows(
            for: textDocument,
            expansionState: DiffExpansionState(),
            currentFileLines: lines,
            fileKind: .deleted
        )
        let binaryRows = DiffRowSnapshot.rows(
            for: binaryDocument,
            expansionState: DiffExpansionState(),
            currentFileLines: lines,
            fileKind: .modified
        )

        #expect(deletedRows.allSatisfy { row in
            if case .expander = row.content { return false }
            return true
        })
        #expect(binaryRows.allSatisfy { row in
            if case .expander = row.content { return false }
            return true
        })
    }

    private func gapFixtureDocument(truncated: Bool = false) -> FileDiffDocument {
        FileDiffDocument(
            hunks: [
                hunk(oldStart: 11, oldCount: 3, newStart: 11, newCount: 5),
                hunk(oldStart: 31, oldCount: 2, newStart: 33, newCount: 1),
            ],
            truncated: truncated,
            isBinary: false
        )
    }

    private func hunk(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int
    ) -> DiffHunk {
        DiffHunk(
            header: DiffLine(
                kind: .hunkHeader,
                text: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@",
                oldNumber: nil,
                newNumber: nil
            ),
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            sectionContext: nil,
            lines: []
        )
    }
}
