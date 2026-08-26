import Testing

@testable import CmuxMobileChanges

@Suite struct IntraLineDiffTests {
    private let diff = IntraLineDiff()

    @Test func emphasizesSmallMiddleEdit() {
        let result = diff.applying(to: [
            line(.removal, "let total = count"),
            line(.addition, "let total = value"),
        ])

        #expect(emphasizedText(result[0]) == ["count"])
        #expect(emphasizedText(result[1]) == ["value"])
    }

    @Test func suppressesFullLineChangeAboveThreshold() {
        let result = diff.applying(to: [
            line(.removal, "alpha"),
            line(.addition, "omega"),
        ])

        #expect(result[0].emphasisRanges.isEmpty)
        #expect(result[1].emphasisRanges.isEmpty)
    }

    @Test func commonPrefixEmphasizesChangedSuffix() {
        let result = diff.applying(to: [
            line(.removal, "valueOne"),
            line(.addition, "valueTwo"),
        ])

        #expect(emphasizedText(result[0]) == ["One"])
        #expect(emphasizedText(result[1]) == ["Two"])
    }

    @Test func commonSuffixEmphasizesChangedPrefix() {
        let result = diff.applying(to: [
            line(.removal, "oldValue"),
            line(.addition, "newValue"),
        ])

        #expect(emphasizedText(result[0]) == ["old"])
        #expect(emphasizedText(result[1]) == ["new"])
    }

    @Test func pairsMultipleRemovalAndAdditionLinesByIndex() {
        let result = diff.applying(to: [
            line(.context, "before"),
            line(.removal, "itemOne = 1"),
            line(.removal, "itemTwo = 2"),
            line(.addition, "itemOne = 3"),
            line(.addition, "itemTwo = 4"),
            line(.context, "after"),
        ])

        #expect(emphasizedText(result[1]) == ["1"])
        #expect(emphasizedText(result[2]) == ["2"])
        #expect(emphasizedText(result[3]) == ["3"])
        #expect(emphasizedText(result[4]) == ["4"])
        #expect(result[0].emphasisRanges.isEmpty)
        #expect(result[5].emphasisRanges.isEmpty)
    }

    @Test func usesGraphemeBoundariesForEmojiEdits() {
        let result = diff.applying(to: [
            line(.removal, "status: 🟢 ready"),
            line(.addition, "status: 🟡 ready"),
        ])

        #expect(emphasizedText(result[0]) == ["🟢"])
        #expect(emphasizedText(result[1]) == ["🟡"])
    }

    @Test func skipsEmphasisAboveUTF8ByteThreshold() {
        let atThreshold = String(repeating: "é", count: 2_047) + "x"
        let aboveThreshold = String(repeating: "é", count: 2_048)

        let accepted = diff.applying(to: [
            line(.removal, "\(atThreshold)a"),
            line(.addition, "\(atThreshold)b"),
        ])
        let skipped = diff.applying(to: [
            line(.removal, "\(aboveThreshold)a"),
            line(.addition, "\(aboveThreshold)b"),
        ])

        #expect(emphasizedText(accepted[0]) == ["a"])
        #expect(emphasizedText(accepted[1]) == ["b"])
        #expect(skipped[0].emphasisRanges.isEmpty)
        #expect(skipped[1].emphasisRanges.isEmpty)
    }

    private func line(_ kind: DiffLineKind, _ text: String) -> DiffLine {
        DiffLine(kind: kind, text: text, oldNumber: nil, newNumber: nil)
    }

    private func emphasizedText(_ line: DiffLine) -> [String] {
        line.emphasisRanges.map { String(line.text[$0]) }
    }
}
