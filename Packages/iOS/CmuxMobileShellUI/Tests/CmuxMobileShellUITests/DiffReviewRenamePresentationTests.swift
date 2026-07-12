import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite struct DiffReviewRenamePresentationTests {
    @Test func renameOnlyFileShowsSourceAndDestination() throws {
        let data = Data(#"{"path":"New.swift","old_path":"Old.swift","status":"R","additions":0,"deletions":0}"#.utf8)
        let file = try JSONDecoder().decode(MobileWorkspaceDiffStatusResponse.File.self, from: data)

        let presentation = try #require(DiffReviewRenamePresentation(file: file))

        #expect(presentation.text.contains("Old.swift"))
        #expect(presentation.text.contains("New.swift"))
    }
}
