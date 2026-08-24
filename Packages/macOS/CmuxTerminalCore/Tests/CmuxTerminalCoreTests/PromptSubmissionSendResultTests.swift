import Testing
@testable import CmuxTerminalCore

@Suite struct PromptSubmissionSendResultTests {
    @Test func acceptedReflectsWholeTransactionDelivery() {
        #expect(PromptSubmissionSendResult.sent.accepted)
        #expect(PromptSubmissionSendResult.queued.accepted)
        #expect(!PromptSubmissionSendResult.composerBusy.accepted)
        #expect(!PromptSubmissionSendResult.agentScopeUnavailable.accepted)
        #expect(!PromptSubmissionSendResult.unknownKey.accepted)
        #expect(!PromptSubmissionSendResult.inputQueueFull.accepted)
        #expect(!PromptSubmissionSendResult.surfaceUnavailable.accepted)
        #expect(!PromptSubmissionSendResult.processExited.accepted)
    }
}
