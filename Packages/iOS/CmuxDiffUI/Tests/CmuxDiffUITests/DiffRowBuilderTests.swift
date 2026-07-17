import CmuxMobileRPC
import Testing
@testable import CmuxDiffUI

@Suite struct DiffRowBuilderTests {
    @Test func assignsLineNumbersAndLeavesMarkerUnnumbered() {
        let hunk = MobileDiffHunk(
            oldStart: 10,
            oldLines: 3,
            newStart: 20,
            newLines: 3,
            sectionHeading: "body",
            rows: [
                MobileDiffRow(kind: .context, oldNo: 999, newNo: 999, text: "context"),
                MobileDiffRow(kind: .del, text: "old"),
                MobileDiffRow(kind: .noNewline, text: ""),
                MobileDiffRow(kind: .add, text: "new"),
                MobileDiffRow(kind: .context, text: "tail"),
            ]
        )

        let rows = DiffRowBuilder().rows(path: "file.swift", hunks: [hunk])

        #expect(rows[0].text == "@@ -10,3 +20,3 @@ body")
        #expect(rows[1].oldLine == 10 && rows[1].newLine == 20)
        #expect(rows[2].oldLine == 11 && rows[2].newLine == nil)
        #expect(rows[3].oldLine == nil && rows[3].newLine == nil)
        #expect(rows[4].oldLine == nil && rows[4].newLine == 21)
        #expect(rows[5].oldLine == 12 && rows[5].newLine == 22)
    }

    @Test func omitsEmptySectionHeadingFromHeader() {
        let hunk = MobileDiffHunk(
            oldStart: 1,
            oldLines: 0,
            newStart: 1,
            newLines: 1,
            sectionHeading: "",
            rows: [MobileDiffRow(kind: .add, text: "new")]
        )

        let rows = DiffRowBuilder().rows(path: "file.swift", hunks: [hunk])

        #expect(rows.first?.text == "@@ -1,0 +1,1 @@")
    }
}
