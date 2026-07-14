import CmuxMobileRPC
import Testing

@testable import CmuxMobileDiff

@Suite struct SplitDiffRowBuilderTests {
    @Test func pairsChangeRunsAndPadsMissingNewCells() {
        let rows = splitRows([
            MobileChangesDiffRow(kind: .del, oldNo: 10, newNo: nil, text: "old one"),
            MobileChangesDiffRow(kind: .del, oldNo: 11, newNo: nil, text: "old two"),
            MobileChangesDiffRow(kind: .add, oldNo: nil, newNo: 10, text: "new one"),
        ])
        let code = rows.filter { $0.splitOldSide != nil || $0.splitNewSide != nil }
        #expect(code.count == 2)
        #expect(code[0].splitOldSide?.lineNumber == 10)
        #expect(code[0].splitNewSide?.lineNumber == 10)
        #expect(code[1].splitOldSide?.lineNumber == 11)
        #expect(code[1].splitNewSide == nil)
    }

    @Test func padsMissingOldCellsForExtraAdditions() {
        let rows = splitRows([
            MobileChangesDiffRow(kind: .del, oldNo: 20, newNo: nil, text: "old"),
            MobileChangesDiffRow(kind: .add, oldNo: nil, newNo: 20, text: "new one"),
            MobileChangesDiffRow(kind: .add, oldNo: nil, newNo: 21, text: "new two"),
        ])
        let code = rows.filter { $0.splitOldSide != nil || $0.splitNewSide != nil }
        #expect(code.count == 2)
        #expect(code[0].splitOldSide?.lineNumber == 20)
        #expect(code[0].splitNewSide?.lineNumber == 20)
        #expect(code[1].splitOldSide == nil)
        #expect(code[1].splitNewSide?.lineNumber == 21)
    }

    @Test func contextUsesIndependentOldAndNewGutters() throws {
        let rows = splitRows([
            MobileChangesDiffRow(kind: .context, oldNo: 30, newNo: 35, text: "shared"),
        ])
        let row = try #require(rows.first { $0.splitOldSide != nil })
        #expect(row.splitOldSide?.lineNumber == 30)
        #expect(row.splitNewSide?.lineNumber == 35)
        #expect(row.splitOldSide?.text == "shared")
        #expect(row.splitNewSide?.text == "shared")
    }

    @Test func pairedSidesRetainIntralineRangesAndSourceAnchors() throws {
        let rows = splitRows([
            MobileChangesDiffRow(kind: .del, oldNo: 4, newNo: nil, text: "let color = red"),
            MobileChangesDiffRow(kind: .add, oldNo: nil, newNo: 4, text: "let color = blue"),
        ])
        let row = try #require(rows.first { $0.splitOldSide != nil })
        #expect(row.splitOldSide?.intralineRanges.isEmpty == false)
        #expect(row.splitNewSide?.intralineRanges.isEmpty == false)
        #expect(row.sourceRowIDs.count == 2)
        #expect(row.sourceRowIDs.contains(row.splitOldSide?.sourceID ?? ""))
        #expect(row.sourceRowIDs.contains(row.splitNewSide?.sourceID ?? ""))
    }

    private func splitRows(_ rows: [MobileChangesDiffRow]) -> [DiffRowSnapshot] {
        DiffRowBuilder().rows(
            file: MobileChangesFile(
                path: "Sources/App.swift",
                oldPath: nil,
                status: .modified,
                additions: rows.filter { $0.kind == .add }.count,
                deletions: rows.filter { $0.kind == .del }.count,
                isBinary: false,
                isLarge: false,
                patchDigest: "digest"
            ),
            hunks: [MobileChangesHunk(
                oldStart: 1,
                oldLines: rows.filter { $0.kind != .add }.count,
                newStart: 1,
                newLines: rows.filter { $0.kind != .del }.count,
                sectionHeading: nil,
                rows: rows
            )],
            includeEOFGap: false,
            mode: .split
        )
    }
}
