import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A Feed row in the main Chief's transcript (``HomeFeedRow``) is a line from the Feed, not a message
/// from the Chief. User 2026-11-09: "cmux updated should not be 'sent by chief'": the update line drew
/// under the Chief's name and beside its avatar.
@Suite struct HomeFeedRowMappingTests {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let chief = ParticipantID("agent_mux")

    static var summary: ConversationSummary {
        let people = [CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        return ConversationSummary(id: ConversationID("c"), title: "Chief", participants: people, lastSeq: 1,
                                   createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
    }

    static var updateRow: TranscriptItem {
        let row = HomeFeedRow(id: "fi_1", source: "cmux", title: "cmux updated to nightly 4295228", url: nil, date: base)
        var item = TranscriptItem(key: IdempotencyKey("feed:fi_1"), seq: nil, author: HomeFeedRow.author,
                                  parts: [.text(row.line)], createdAt: base, delivery: .committed)
        item.isReadOnly = true
        item.feedRow = row
        return item
    }

    @Test func anUpdateLineIsNotTheChiefs() {
        let message = HomeMapping.message(Self.updateRow, aliases: [:], me: ParticipantID("user_local"), summary: Self.summary)
        #expect(message.senderId != Self.chief.rawValue)
        // No sender's name over it and no avatar beside it (Layout.swift draws neither for an aside).
        #expect(message.cmuxAside == true)
    }
}
