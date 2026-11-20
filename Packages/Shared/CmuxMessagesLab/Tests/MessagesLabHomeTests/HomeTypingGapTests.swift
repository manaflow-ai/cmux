import Foundation
import Testing
@testable import MessagesLabHome

/// The typing bubble under the newest message sits 14 pt under it body to body, so its top stays clear of the
/// bubble above and that bubble's tail (user, 2026-10-30: "we need more space in between typing bubble and the
/// latest message"; it sat 4.3 pt under the Chief's own tail; at 8 pt, "maybe even more padding").
@MainActor @Suite struct HomeTypingGapTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func message(_ id: String, _ sender: String, at t: Double) -> Message {
        Message(id: id, senderId: sender, sentAt: Instant.format(t0.addingTimeInterval(t)), parts: [.text("hello there", runs: [])],
                replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    static func state(_ messages: [Message], notice: String? = nil) -> AppState {
        var s = AppState(conversation: Conversation(id: "c", title: "Chief", participants: [
            Participant(id: "me", displayName: "Me", isMe: true, avatar: nil),
            Participant(id: "chief", displayName: "Chief", isMe: false, avatar: nil),
        ], messages: messages))
        s.ui.typing = ["chief"]
        s.ui.notice = notice
        return s
    }

    /// Points from the bottom of the row above the typing row to the typing bubble's top.
    static func clearance(_ s: AppState) throws -> CGFloat {
        let rows = RowBuilder.rows(s, messages: s.conversation.messages, now: t0.addingTimeInterval(30))
        let i = try #require(rows.firstIndex { $0.key == "typing" })
        let typing = try #require(rows[checked: i])
        return typing.gap + RowDraw.typingBubble.minY - RowDraw.margin
    }

    @Test(arguments: ["chief", "me"])
    func theTypingBubbleSits14PointsUnderTheNewestBubble(sender: String) throws {
        let gap = try Self.clearance(Self.state([Self.message("m1", sender, at: 0)]))
        #expect(abs(gap - 14) < 0.01, "typing bubble is \(gap) pt under the newest bubble, want 14")
    }

    /// User 2026-10-30 5:03 PM ("make it just one line with shimmer text"): under the newest bubble the
    /// status line alone is the running indicator, with no typing bubble under it (HomeNoticeShimmer).
    @Test func theStatusLineReplacesTheTypingBubble() throws {
        let rows = RowBuilder.rows(Self.state([Self.message("m1", "chief", at: 0)], notice: "Running · 4s"),
                                   messages: [Self.message("m1", "chief", at: 0)], now: Self.t0)
        #expect(rows.contains { $0.key == "notice" })
        #expect(!rows.contains { $0.key == "typing" })
    }
}
