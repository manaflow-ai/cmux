import CMUXMobileCore
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

    @Test func descriptionBoundsUTF8Bytes() {
        let draft = WorkspaceCustomizationDraft(
            name: "Workspace",
            customDescription: String(repeating: "🧪", count: 2_000),
            customColorHex: nil,
            isPinned: false
        )

        #expect(
            draft.customDescription?.utf8.count
                == MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes
        )
    }

    @Test func rebasePreservesDirtyFieldsAndAppliesUntouchedFields() {
        let initial = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: "Old description",
            customColorHex: "#111111",
            isPinned: false
        )
        let submitted = WorkspaceCustomizationDraft(
            name: "Edited",
            customDescription: "Old description",
            customColorHex: "#111111",
            isPinned: false
        )
        let authoritative = WorkspaceCustomizationDraft(
            name: "Concurrent rename",
            customDescription: "Concurrent description",
            customColorHex: "#222222",
            isPinned: true
        )

        let rebased = submitted.rebasingUntouchedFields(
            from: authoritative,
            comparedTo: initial
        )

        #expect(rebased.name == "Edited")
        #expect(rebased.customDescription == "Concurrent description")
        #expect(rebased.customColorHex == "#222222")
        #expect(rebased.isPinned)
    }
}
