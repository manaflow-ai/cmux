import CmuxMobileShellModel
import Foundation
import Testing

struct MobileTaskComposerSavedDraftTests {
    @Test func savedDraftRoundTripsThroughCodable() throws {
        let draft = MobileTaskComposerSavedDraft(
            updatedAt: Date(timeIntervalSince1970: 1_755_000_000),
            content: MobileTaskComposerDraft(
                prompt: "Build the drafts feature\nwith tests",
                modelID: "model-1",
                effortID: "high",
                templateID: UUID(),
                macDeviceID: "mac-a",
                macInstanceTag: "drft",
                directory: "~/Dev/cmux",
                didEditDirectory: true,
                workspaceName: "Drafts",
                operationID: UUID(),
                completedOperationID: UUID()
            )
        )

        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(MobileTaskComposerSavedDraft.self, from: data)

        #expect(decoded == draft)
        #expect(decoded.id == draft.id)
        #expect(decoded.content.completedOperationID == draft.content.completedOperationID)
    }

    @Test func whitespaceOnlyPromptAndNameIsEffectivelyEmpty() {
        var draft = MobileTaskComposerDraft(
            prompt: " \n\t ",
            templateID: UUID(),
            macDeviceID: "mac-a",
            directory: "~/Dev/cmux",
            didEditDirectory: true,
            workspaceName: "  "
        )
        #expect(draft.isEffectivelyEmpty)

        draft.prompt = "Fix the bug"
        #expect(!draft.isEffectivelyEmpty)
    }

    @Test func workspaceNameAloneKeepsADraft() {
        let draft = MobileTaskComposerDraft(
            prompt: "",
            templateID: nil,
            macDeviceID: nil,
            directory: "~",
            didEditDirectory: false,
            workspaceName: "Prepared workspace"
        )
        #expect(!draft.isEffectivelyEmpty)
    }

    @Test func completedOperationAnchorKeepsAnOtherwiseEmptyDraft() {
        let draft = MobileTaskComposerDraft(
            prompt: "",
            templateID: nil,
            macDeviceID: nil,
            directory: "~",
            didEditDirectory: false,
            completedOperationID: UUID()
        )
        #expect(!draft.isEffectivelyEmpty)
    }
}
