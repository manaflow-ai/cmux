import Testing
@testable import CmuxDiffUI

@Suite struct SplitDiffPairerTests {
    @Test func alignsUnequalDeletionAndAdditionRuns() {
        let rows = [
            row("d1", .deletion, old: 4, new: nil),
            row("d2", .deletion, old: 5, new: nil),
            row("a1", .addition, old: nil, new: 4),
        ]

        let split = SplitDiffPairer().pair(rows: rows)

        #expect(split.count == 2)
        #expect(split[0].old?.id == "d1" && split[0].new?.id == "a1")
        #expect(split[1].old?.id == "d2" && split[1].new == nil)
    }

    @Test func contextAppearsOnBothSides() {
        let context = row("context", .context, old: 7, new: 8)

        let split = SplitDiffPairer().pair(rows: [context])

        #expect(split.first?.old == context)
        #expect(split.first?.new == context)
    }

    @Test func hunkAndNoNewlineRowsSpanBothColumns() {
        let rows = [
            row("header", .hunkHeader, old: nil, new: nil),
            row("marker", .noNewline, old: nil, new: nil),
        ]

        let split = SplitDiffPairer().pair(rows: rows)

        #expect(split.map(\.kind) == [.spanning, .spanning])
        #expect(split.map { $0.spanning?.id } == ["header", "marker"])
    }

    private func row(_ id: String, _ kind: DiffRowKind, old: Int?, new: Int?) -> DiffRowSnapshot {
        DiffRowSnapshot(
            id: id,
            kind: kind,
            oldLine: old,
            newLine: new,
            text: id,
            hunkIndex: 0
        )
    }
}
