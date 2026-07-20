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

    @Test func completedOperationRecoverySurvivesDraftRoundTrip() throws {
        let freshOperationID = UUID()
        let completedOperationID = UUID()
        let draft = MobileTaskComposerDraft(
            prompt: "Keep this draft",
            templateID: UUID(),
            macDeviceID: "mac-a",
            directory: "~/Dev/cmux",
            didEditDirectory: true,
            operationID: freshOperationID,
            completedOperationID: completedOperationID
        )

        let restored = try JSONDecoder().decode(
            MobileTaskComposerDraft.self,
            from: JSONEncoder().encode(draft)
        )

        #expect(restored == draft)
        #expect(restored.operationID == freshOperationID)
        #expect(restored.completedOperationID == completedOperationID)
    }
}
