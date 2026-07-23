import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceCustomizationDraftTests {
    @Test func descriptionNormalizesLineEndingsAndTrimsEdgeWhitespace() {
        let draft = WorkspaceCustomizationDraft(
            name: "Workspace",
            customDescription: "  Release\r\nvalidation  ",
            customColorHex: nil,
            isPinned: false
        )

        #expect(draft.customDescription == "Release\nvalidation")
    }
}
