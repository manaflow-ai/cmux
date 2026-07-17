import Testing
@testable import CmuxDiffUI

@Suite struct IntralineDifferTests {
    @Test func pureAdditionAndDeletionEmphasizeTheWholePresentSide() {
        let differ = IntralineDiffer()
        let addition = differ.changedRanges(old: "", new: "hello world")
        let deletion = differ.changedRanges(old: "goodbye", new: "")

        #expect(addition.old == nil)
        #expect(addition.new == TextRange(lowerBound: 0, upperBound: 11))
        #expect(deletion.old == TextRange(lowerBound: 0, upperBound: 7))
        #expect(deletion.new == nil)
    }

    @Test func commonPrefixAndSuffixLeaveOnlyChangedWords() {
        let ranges = IntralineDiffer().changedRanges(
            old: "let greeting = hello world",
            new: "let greeting = welcome world"
        )

        #expect(ranges.old == TextRange(lowerBound: 15, upperBound: 20))
        #expect(ranges.new == TextRange(lowerBound: 15, upperBound: 22))
    }

    @Test func equalDeletionAndAdditionCountsPairByPosition() {
        let rows = [
            row(id: "d1", kind: .deletion, text: "let value = old"),
            row(id: "d2", kind: .deletion, text: "return old"),
            row(id: "a1", kind: .addition, text: "let value = new"),
            row(id: "a2", kind: .addition, text: "return new"),
        ]

        let paired = DiffRowIntralinePairer().apply(to: rows)

        #expect(paired.allSatisfy { !$0.intralineSpans.isEmpty })
        #expect(paired[0].intralineSpans.contains { $0.isEmphasized && $0.text == "old" })
        #expect(paired[2].intralineSpans.contains { $0.isEmphasized && $0.text == "new" })
    }

    @Test func unpairedPureAdditionAndDeletionRunsRemainUnemphasized() {
        let deletion = DiffRowIntralinePairer().apply(to: [
            row(id: "d", kind: .deletion, text: "removed"),
        ])
        let addition = DiffRowIntralinePairer().apply(to: [
            row(id: "a", kind: .addition, text: "added"),
        ])

        #expect(deletion[0].intralineSpans.isEmpty)
        #expect(addition[0].intralineSpans.isEmpty)
    }

    @Test func separateChangeRunsDoNotPairAcrossContext() {
        let rows = [
            row(id: "d1", kind: .deletion, text: "old one"),
            row(id: "a1", kind: .addition, text: "new one"),
            row(id: "c", kind: .context, text: "separator"),
            row(id: "d2", kind: .deletion, text: "old two"),
            row(id: "a2", kind: .addition, text: "new two"),
        ]

        let paired = DiffRowIntralinePairer().apply(to: rows)

        #expect(paired[0].intralineSpans.contains { $0.isEmphasized && $0.text == "old" })
        #expect(paired[1].intralineSpans.contains { $0.isEmphasized && $0.text == "new" })
        #expect(paired[2].intralineSpans.isEmpty)
        #expect(paired[3].intralineSpans.contains { $0.isEmphasized && $0.text == "old" })
        #expect(paired[4].intralineSpans.contains { $0.isEmphasized && $0.text == "new" })
    }

    private func row(id: String, kind: DiffRowKind, text: String) -> DiffRowSnapshot {
        DiffRowSnapshot(
            id: id,
            kind: kind,
            oldLine: nil,
            newLine: nil,
            text: text,
            hunkIndex: 0
        )
    }
}
