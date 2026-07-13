import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskComposerDraftTests {
    @Test func templateSelectionPreservesManuallyEditedDirectory() {
        let originalTemplateID = UUID()
        let selectedTemplateID = UUID()
        var draft = MobileTaskComposerDraft(
            prompt: "Keep the path",
            templateID: originalTemplateID,
            macDeviceID: "mac-a",
            directory: "/Users/test/Manual",
            didEditDirectory: true
        )

        draft.selectTemplate(
            id: selectedTemplateID,
            suggestedDirectory: "/Users/test/Suggested"
        )

        #expect(draft.templateID == selectedTemplateID)
        #expect(draft.directory == "/Users/test/Manual")
        #expect(draft.didEditDirectory)
    }

    @Test func templateSelectionAppliesSuggestionUntilDirectoryIsEdited() {
        let selectedTemplateID = UUID()
        var draft = MobileTaskComposerDraft(
            prompt: "",
            templateID: UUID(),
            macDeviceID: "mac-a",
            directory: "~",
            didEditDirectory: false
        )

        draft.selectTemplate(
            id: selectedTemplateID,
            suggestedDirectory: "/Users/test/Suggested"
        )

        #expect(draft.templateID == selectedTemplateID)
        #expect(draft.directory == "/Users/test/Suggested")
        #expect(!draft.didEditDirectory)
    }
}
