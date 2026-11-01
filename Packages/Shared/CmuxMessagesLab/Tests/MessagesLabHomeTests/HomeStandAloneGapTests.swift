import Foundation
import Testing
@testable import MessagesLabHome

/// Chief's first-launch welcome is three short bubbles that arrive one by one; each stands alone, 14 pt under the
/// one above with its own tail, where its typing dots sat (user, 2026-10-31: "more spaced out"). Other messages of
/// one sender within a minute keep Messages' 3 pt group with one tail.
@MainActor @Suite struct HomeStandAloneGapTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func message(_ id: String, alone: Bool) -> Message {
        var m = Message(id: id, senderId: "chief", sentAt: Instant.format(t0), parts: [.text("hello there", runs: [])],
                        replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
        if alone { m.cmuxStandsAlone = true }
        return m
    }

    static func rows(alone: Bool) -> [RowSpec] {
        let messages = ["m1", "m2", "m3"].map { message($0, alone: alone) }
        let s = AppState(conversation: Conversation(id: "c", title: "Chief", participants: [
            Participant(id: "me", displayName: "Me", isMe: true, avatar: nil),
            Participant(id: "chief", displayName: "Chief", isMe: false, avatar: nil),
        ], messages: messages))
        return RowBuilder.rows(s, messages: messages, now: t0)
    }

    static func bubbles(_ rows: [RowSpec]) -> [(gap: CGFloat, tail: Bool)] {
        rows.compactMap { row in
            guard case let .part(spec) = row.kind else { return nil }
            return (row.gap, spec.tail)
        }
    }

    @Test func welcomeBubblesStand14PointsApartEachWithItsTail() {
        let bubbles = Self.bubbles(Self.rows(alone: true))
        #expect(bubbles.count == 3)
        #expect(bubbles.dropFirst().allSatisfy { $0.gap == 14 })
        #expect(bubbles.map(\.tail) == [true, true, true])
        #expect(RowBuilder.standAloneGap == RowBuilder.typingGapUnderBubble + RowDraw.typingBubble.minY - RowDraw.margin)
    }

    @Test func otherMessagesKeepMessagesGrouping() {
        let bubbles = Self.bubbles(Self.rows(alone: false))
        #expect(bubbles.count == 3)
        #expect(bubbles.dropFirst().allSatisfy { $0.gap == 3 })
        #expect(bubbles.map(\.tail) == [false, false, true])
    }
}
