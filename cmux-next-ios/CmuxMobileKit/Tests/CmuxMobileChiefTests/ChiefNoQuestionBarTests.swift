import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// Aziz 2026-11-10: "get rid of this toast". Chief's open question no longer
/// pins a "Chief is asking · Answer" bar over the conversation; Chief asks in
/// its message, and a reply in the chat answers it.
@MainActor
@Suite struct ChiefNoQuestionBarTests {
    @Test(.timeLimit(.minutes(1))) func anOpenQuestionShowsNoBar() async throws {
        // The mock Chief starts with one pending question.
        let session = ChiefSession(backend: ChiefMockBackend(sleep: { _ in }), outbox: ChiefOutbox(file: nil))
        defer { session.store.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        while session.openQuestion == nil, ContinuousClock.now < deadline {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(session.openQuestion != nil)
        #expect(session.barItem == nil)
    }
}
