import Testing

@testable import CmuxAgentChatUI

@Suite("Chat attachment staging ownership")
@MainActor
struct ChatAttachmentStagingTaskOwnerTests {
    @Test("photo staging reserves external attachment admission")
    func photoStagingReservesExternalAttachmentAdmission() {
        let owner = ChatAttachmentStagingTaskOwner()
        #expect(owner.canAcceptExternalAttachment)

        owner.start { _ in
            try? await ContinuousClock().sleep(for: .seconds(60))
        }
        #expect(!owner.canAcceptExternalAttachment)

        owner.cancel()
        #expect(owner.canAcceptExternalAttachment)
    }

    @Test("replacement and cancellation keep busy state with the current task")
    func replacementAndCancellationOwnBusyState() {
        let owner = ChatAttachmentStagingTaskOwner()

        owner.start { _ in
            try? await ContinuousClock().sleep(for: .seconds(60))
        }
        let firstGeneration = owner.generation
        #expect(owner.isBusy)
        #expect(owner.task != nil)

        owner.start { _ in
            try? await ContinuousClock().sleep(for: .seconds(60))
        }
        #expect(owner.generation != firstGeneration)
        #expect(owner.isBusy)
        #expect(owner.task != nil)

        owner.cancel()
        #expect(!owner.isBusy)
        #expect(owner.task == nil)
    }
}
