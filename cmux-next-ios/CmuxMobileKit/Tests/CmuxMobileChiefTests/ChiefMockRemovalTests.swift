import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// Chief with no Mac is offline and empty; the scripted mock Chief needs the
/// explicit mock data switch (DEBUG only).
@MainActor @Suite struct ChiefFallbackTests {
    @Test func noMacMeansOfflineChief() async throws {
        let backend = ChiefSession.fallbackBackend(mockContentEnabled: false)
        #expect(backend is ChiefOfflineBackend)
        let page = try await backend.history(beforeSeq: nil, limit: 50)
        #expect(page.messages.isEmpty)
        var iterator = backend.events().makeAsyncIterator()
        guard case .disconnected = await iterator.next() else {
            Issue.record("the offline Chief must report itself disconnected")
            return
        }
        await #expect(throws: ConversationBackendError.self) { try await backend.edit(messageID: "m1", text: "hello") }
    }

    #if DEBUG
    @Test func mockChiefOnlyWithTheExplicitSwitch() {
        #expect(ChiefSession.fallbackBackend(mockContentEnabled: true) is ChiefMockBackend)
    }
    #endif
}
