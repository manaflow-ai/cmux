import CmuxDiffModel
import Testing

@testable import CmuxMobileShellUI

@Suite struct DiffReviewRenamePresentationTests {
    @Test func renameOnlyFileShowsSourceAndDestination() throws {
        let file = DiffFileSummary(
            path: "New.swift",
            oldPath: "Old.swift",
            status: .renamed,
            additions: 0,
            deletions: 0
        )

        let presentation = try #require(DiffReviewRenamePresentation(file: file))

        #expect(presentation.text.contains("Old.swift"))
        #expect(presentation.text.contains("New.swift"))
    }

    @Test func textHunkRetainsModeMetadata() {
        let file = DiffFileSummary(
            path: "Script.sh",
            oldPath: nil,
            status: .modified,
            additions: 1,
            deletions: 1
        )
        let hunk = DiffHunk(
            id: 0,
            header: "@@ -1 +1 @@",
            oldStart: 1,
            oldCount: 1,
            newStart: 1,
            newCount: 1,
            lines: []
        )
        let metadata = ["old mode 100644", "new mode 100755"]

        let presentation = DiffReviewContentPresentation(
            file: file,
            hunks: [hunk],
            metadataLines: metadata
        )

        #expect(presentation.metadataLines == metadata)
    }

    @Test func binaryRenameRetainsBinaryMetadata() throws {
        let file = DiffFileSummary(
            path: "New.bin",
            oldPath: "Old.bin",
            status: .renamed,
            additions: nil,
            deletions: nil
        )
        let metadata = ["Binary files a/Old.bin and b/New.bin differ"]

        let presentation = DiffReviewContentPresentation(
            file: file,
            hunks: [],
            metadataLines: metadata
        )

        #expect(try #require(presentation.rename).text.contains("Old.bin"))
        #expect(presentation.metadataLines == metadata)
    }
}
