import Foundation
import Testing
@testable import CmuxHomeCore

/// The Feed's notices in the main Chief's transcript (``HomeFeedRow``): read-only lines merged by time.
struct HomeFeedRowTests {
    let chief = ParticipantID("agent_mux")

    func message(_ id: String, at seconds: TimeInterval, delivery: TranscriptItem.Delivery = .committed) -> TranscriptItem {
        .init(key: IdempotencyKey(id), seq: 1, author: ParticipantID("user"), parts: [.text(id)],
              createdAt: Date(timeIntervalSince1970: seconds), delivery: delivery, messageID: MessageID(id))
    }

    func row(_ id: String, at seconds: TimeInterval) -> HomeFeedRow {
        .init(id: id, source: "GitHub", title: "PR \(id) merged", url: URL(string: "https://github.com/o/r/pull/1"),
              date: Date(timeIntervalSince1970: seconds))
    }

    @Test func rowsSitAtTheirTimeBetweenMessages() {
        let items = HomeFeedRow.inserting([row("late", at: 300), row("early", at: 50), row("mid", at: 150)],
                                          into: [message("a", at: 100), message("b", at: 200)], author: chief)
        #expect(items.map(\.key) == ["feed:early", "a", "feed:mid", "b", "feed:late"].map { IdempotencyKey($0) })
    }

    @Test func aRowIsReadOnlyAndNeverAConversationMessage() throws {
        let item = try #require(HomeFeedRow.inserting([row("1", at: 10)], into: [], author: chief).first)
        #expect(item.isReadOnly)
        #expect(item.messageID == nil)
        #expect(item.feedRow?.url?.absoluteString == "https://github.com/o/r/pull/1")
        #expect(item.plainText == "GitHub · PR 1 merged")
    }

    @Test func aPendingSendStaysLast() {
        let items = HomeFeedRow.inserting([row("new", at: 500)],
                                          into: [message("a", at: 100), message("sending", at: 400, delivery: .sending)], author: chief)
        #expect(items.map(\.key) == ["a", "feed:new", "sending"].map { IdempotencyKey($0) })
    }

    @Test func noRowsLeavesTheTranscriptAsIs() {
        let items = [message("a", at: 100)]
        #expect(HomeFeedRow.inserting([], into: items, author: chief).map(\.key) == items.map(\.key))
    }

    @Test func aWindowShortOfTheStartHoldsBackOlderRows() {
        let items = HomeFeedRow.inserting([row("old", at: 10), row("new", at: 150)], into: [message("a", at: 100)],
                                          author: chief, since: Date(timeIntervalSince1970: 100))
        #expect(items.map(\.key) == ["a", "feed:new"].map { IdempotencyKey($0) })
    }
}
