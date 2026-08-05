import Testing
@testable import CmuxAgentChatUI

@Suite("Chat composer send policy")
struct ChatComposerSendPolicyTests {
    @Test("default composer remains disabled while disconnected")
    func defaultDisconnected() {
        #expect(!ChatComposerSendPolicy.canSubmit(isConnected: false, capabilities: .all))
    }

    @Test("Agent GUI text composer can enqueue while disconnected")
    func offlineQueue() {
        #expect(ChatComposerSendPolicy.canSubmit(isConnected: false, capabilities: .textOnly))
    }

    @Test("read-only sessions cannot submit while connected")
    func readOnly() {
        #expect(!ChatComposerSendPolicy.canSubmit(isConnected: true, capabilities: .readOnly))
    }
}
