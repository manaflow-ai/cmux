import Foundation
import Testing
@testable import CmuxAgentChatUI

@Suite
struct ChatArtifactActionVisibilityPolicyTests {
    @Test
    func imageOffersShareSaveAndCopyImage() {
        let policy = ChatArtifactActionVisibilityPolicy(inlineState: .image(data: Data()))

        #expect(policy.actions == [.share, .save, .copyImage])
    }

    @Test
    func documentPreviewsOfferShareAndSave() {
        let url = URL(fileURLWithPath: "/tmp/artifact")

        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .pdf(fileURL: url)).actions == [.share, .save])
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .media(fileURL: url)).actions == [.share, .save])
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .quickLook(fileURL: url)).actions == [.share, .save])
    }

    @Test
    func loadingAndErrorStatesOfferNoActions() {
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .loading).actions.isEmpty)
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .fileMissing).actions.isEmpty)
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .macUnreachable).actions.isEmpty)
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .forbidden).actions.isEmpty)
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .unsupportedMedia).actions.isEmpty)
    }

    @Test
    func nonPreviewContentOffersNoInlineActions() {
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .folder).actions.isEmpty)
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .text).actions.isEmpty)
        #expect(ChatArtifactActionVisibilityPolicy(inlineState: .markdown).actions.isEmpty)
        #expect(ChatArtifactActionVisibilityPolicy(
            inlineState: .tooLarge(actualSize: 10, limit: 5)
        ).actions.isEmpty)
    }

    @Test
    func fullViewerFileActionsKeepExistingMapping() {
        #expect(ChatArtifactActionVisibilityPolicy(
            viewerHasFileActions: true,
            isTextFile: false
        ).actions == [.share, .save, .copyPath])
        #expect(ChatArtifactActionVisibilityPolicy(
            viewerHasFileActions: true,
            isTextFile: true
        ).actions == [.share, .save, .copyContents, .copyPath])
        #expect(ChatArtifactActionVisibilityPolicy(
            viewerHasFileActions: false,
            isTextFile: false
        ).actions.isEmpty)
    }
}
