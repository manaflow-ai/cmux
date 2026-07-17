import CmuxMobileRPC
import Testing

@testable import CmuxMobileDiff

@Suite struct DiffRowBuilderTests {
    @Test func preservesNumbersAcrossMultipleHunksAndBuildsAllGapKinds() throws {
        let first = MobileChangesHunk(
            oldStart: 10,
            oldLines: 3,
            newStart: 10,
            newLines: 4,
            sectionHeading: "first",
            rows: [
                row(.context, 10, 10, "a"),
                row(.del, 11, nil, "old"),
                row(.add, nil, 11, "new"),
                row(.add, nil, 12, "extra"),
                row(.context, 12, 13, "z"),
            ]
        )
        let second = MobileChangesHunk(
            oldStart: 30,
            oldLines: 1,
            newStart: 31,
            newLines: 1,
            sectionHeading: nil,
            rows: [row(.context, 30, 31, "later")]
        )
        let rows = DiffRowBuilder().rows(file: file(), hunks: [first, second])
        let code = rows.filter { [.context, .addition, .deletion].contains($0.kind) }
        #expect(code.map(\.oldLineNumber) == [10, 11, nil, nil, 12, 30])
        #expect(code.map(\.newLineNumber) == [10, nil, 11, 12, 13, 31])

        let gaps = rows.compactMap(\.expansionGap)
        #expect(gaps.count == 3)
        #expect(gaps[0].newStart == 1)
        #expect(gaps[0].newEnd == 9)
        #expect(gaps[1].newStart == 14)
        #expect(gaps[1].newEnd == 30)
        #expect(gaps[1].oldLineDelta == -1)
        #expect(gaps[2].newStart == 32)
        #expect(gaps[2].newEnd == nil)
    }

    @Test func preservesNoNewlineMarker() throws {
        let hunk = MobileChangesHunk(
            oldStart: 1,
            oldLines: 1,
            newStart: 1,
            newLines: 1,
            sectionHeading: nil,
            rows: [row(.noNewline, nil, nil, "")]
        )
        let marker = try #require(DiffRowBuilder().rows(file: file(), hunks: [hunk]).first { $0.kind == .noNewline })
        #expect(marker.marker == "\\")
    }

    @Test func runCapSkipsIntralineRanges() {
        let rows = [
            row(.del, 1, nil, "old one"),
            row(.del, 2, nil, "old two"),
            row(.add, nil, 1, "new one"),
            row(.add, nil, 2, "new two"),
        ]
        let hunk = MobileChangesHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, sectionHeading: nil, rows: rows)
        let built = DiffRowBuilder(maximumIntralineRun: 1).rows(file: file(), hunks: [hunk])
        #expect(built.allSatisfy { $0.intralineRanges.isEmpty })
    }

    @Test func gutterDigitsUseVisibleMaximum() {
        #expect(DiffFileSnapshot.gutterDigits(nil) == 1)
        #expect(DiffFileSnapshot.gutterDigits(9) == 1)
        #expect(DiffFileSnapshot.gutterDigits(10) == 2)
        #expect(DiffFileSnapshot.gutterDigits(10_000) == 5)
    }

    private func row(_ kind: MobileChangesRowKind, _ old: Int?, _ new: Int?, _ text: String) -> MobileChangesDiffRow {
        MobileChangesDiffRow(kind: kind, oldNo: old, newNo: new, text: text)
    }

    private func file() -> MobileChangesFile {
        MobileChangesFile(
            path: "Sources/App.swift",
            oldPath: nil,
            status: .modified,
            additions: 2,
            deletions: 1,
            isBinary: false,
            isLarge: false,
            patchDigest: "digest"
        )
    }
}
