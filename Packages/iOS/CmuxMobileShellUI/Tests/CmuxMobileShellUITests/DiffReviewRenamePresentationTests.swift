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
}
