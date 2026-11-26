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

    @Test func attachmentsAloneKeepADraft() {
        let draft = MobileTaskComposerDraft(
            prompt: "",
            templateID: nil,
            macDeviceID: nil,
            directory: "~",
            didEditDirectory: false,
            attachments: [MobileTaskComposerDraftAttachment(
                id: UUID(),
                kind: "image",
                displayName: "screenshot.png",
                relativePath: "d/a.png",
                byteCount: 42
            )]
        )
        #expect(!draft.isEffectivelyEmpty)
    }

    @Test func legacyDraftJSONWithoutAttachmentsDecodesAsEmpty() throws {
        let legacyJSON = """
        {"prompt":"Old build draft","directory":"~","didEditDirectory":true}
        """
        let decoded = try JSONDecoder().decode(
            MobileTaskComposerDraft.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.attachments.isEmpty)
        #expect(decoded.prompt == "Old build draft")
        #expect(decoded.didEditDirectory)
    }

    @Test func draftAttachmentsRoundTripThroughCodable() throws {
        let attachment = MobileTaskComposerDraftAttachment(
            id: UUID(),
            kind: TaskComposerAttachment.Kind.image.persistedValue,
            displayName: "IMG_0001.heic",
            relativePath: "draft-id/attachment-id.heic",
            byteCount: 1_234,
            thumbnailData: Data([1, 2, 3])
        )
        let draft = MobileTaskComposerDraft(
            prompt: "With attachment",
            templateID: nil,
            macDeviceID: nil,
            directory: "~",
            didEditDirectory: false,
            attachments: [attachment]
        )

        let decoded = try JSONDecoder().decode(
            MobileTaskComposerDraft.self,
            from: JSONEncoder().encode(draft)
        )

        #expect(decoded == draft)
        #expect(decoded.attachments == [attachment])
        #expect(TaskComposerAttachment.Kind(persistedValue: decoded.attachments[0].kind) == .image)
        #expect(TaskComposerAttachment.Kind(persistedValue: "file") == .file)
        #expect(TaskComposerAttachment.Kind(persistedValue: "unknown-future-kind") == .file)
    }
}
