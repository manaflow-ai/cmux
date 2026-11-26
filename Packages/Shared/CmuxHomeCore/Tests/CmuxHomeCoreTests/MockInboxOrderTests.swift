import Foundation
import Testing
@testable import CmuxHomeCore

/// The mock owner's inbox lists its conversations as the real one does (`WireHomeSource.inboxSnapshot`): the most
/// recently updated first. It listed them in its dictionary's order, which Swift seeds per dictionary, so two
/// mock owners in one test process listed the same seed in two orders, and a fixture that took "the first
/// conversation with the Chief" got conv_chief from one and conv_core from the other
/// (HomeQueuedAgentPillTests.eachTranscriptOfOneConversationStartsItsOwnAgentFromItsMenu, red on feat-cmux-next).
@Suite struct MockInboxOrderTests {
    @Test func theInboxListsTheMostRecentlyUpdatedFirstInEveryMockOwner() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var orders: [[ConversationID]] = []
        // All alive at once, as the two fixtures of one test are: a freed mock's storage address (its dictionary's
        // seed) is often the next one's.
        var sources: [MockHomeSource] = []
        for _ in 0..<8 {
            let source = MockHomeSource(options: .immediate, now: now)
            sources.append(source)
            let inbox = try await source.inbox()
            let ids = inbox.conversations.map(\.id)
            let newestFirst = inbox.conversations.sorted { ($0.updatedAt, $1.id.rawValue) > ($1.updatedAt, $0.id.rawValue) }.map(\.id)
            #expect(ids == newestFirst, "the mock's inbox is not newest first: \(ids.map(\.rawValue))")
            orders.append(ids)
        }
        #expect(Set(orders.map { $0.map(\.rawValue) }).count == 1, "mock owners over one seed listed it in \(Set(orders.map { $0.map(\.rawValue) }).count) orders")
        withExtendedLifetime(sources) {}
    }
}
