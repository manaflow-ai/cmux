import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// The inline reply's thread line, against Messages on an iPhone 17 Pro
/// Max (iOS 27, dark, 3x screenshot 2026-10-30, points): the line always
/// runs at the leading edge, x 34.0-38.0 (center 36.33 = 20 pt margin +
/// 16.33), arms end at x 69.7. An end on the trailing side is a level arm
/// 2.33 pt under its bubble's middle; an end on the leading side is the
/// line itself, meeting the bubble.
@Suite struct ConversationReplyThreadTests {
    typealias Thread = ConversationReplyThread
    let column: CGFloat = 20 + Thread.columnInset

    /// The path's ink: its bounding box widened by the 4 pt stroke.
    func ink(_ thread: Thread) -> CGRect {
        thread.path.copy(strokingWithWidth: Thread.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10).boundingBoxOfPath
    }

    @Test func theirReplyToMyMessageTurnsOutOfMyQuoteAndDropsToTheirBubble() {
        // "Do u know how to do this properlyv" (incoming) under my "ill merge ok?" with "3 Replies".
        let quote = CGRect(x: 333, y: 247, width: 87.7, height: 29)
        let reply = CGRect(x: 20, y: 297, width: 295.7, height: 44)
        let thread = Thread.row(quote: quote, quoteSide: .trailing, reply: reply, replySide: .leading, columnX: column)
        let box = ink(thread)
        #expect(abs(box.minX - 34.33) < 0.5, "the line's outer edge, as Messages (34.0-34.7)")
        #expect(abs(box.maxX - 70.33) < 0.5, "the arm reaches x 69.7")
        #expect(abs(box.minY - 261.8) < 0.5, "the arm's top edge at the quote's middle (262.0)")
        // Within a point: the screenshot's bubble top (297.0) is its first
        // fully lit row, a hair under the frame edge the layout passes.
        #expect(abs(thread.bottom.y + Thread.lineWidth / 2 - 291.3) < 1, "the line's ink stops at 291.3, 5.7 pt above the reply")
        #expect(thread.top == .arm(y: quote.midY + Thread.armDrop))
    }

    @Test func myReplyToMyMessageIsABracketAtTheLeadingEdge() {
        // "we just need to get the release out…" (mine, two lines) under my "ill merge ok?".
        let quote = CGRect(x: 333, y: 521.3, width: 87.7, height: 29)
        let reply = CGRect(x: 109.7, y: 579.7, width: 309.3, height: 64.7)
        let thread = Thread.row(quote: quote, quoteSide: .trailing, reply: reply, replySide: .trailing, columnX: column)
        let box = ink(thread)
        #expect(abs(box.minX - 34.33) < 0.5)
        #expect(abs(box.maxX - 70.33) < 0.5)
        #expect(abs(box.minY - 536.3) < 0.7, "top arm at the quote's middle (536.3-540.0)")
        #expect(abs(box.maxY - 617.3) < 1.5, "bottom arm at the reply's middle (613.7-617.3)")
        #expect(thread.radius == Thread.bracketRadius, "full 19 pt corners when the bracket is tall enough")
    }

    @Test func myReplyToTheirMessageDropsFromTheirQuoteAndTurnsToMine() {
        // "still going" (mine) under their "how about the cmux cloud dogfooding".
        let quote = CGRect(x: 19.7, y: 679.3, width: 222, height: 29)
        let reply = CGRect(x: 319, y: 718, width: 100.3, height: 44)
        let thread = Thread.row(quote: quote, quoteSide: .leading, reply: reply, replySide: .trailing, columnX: column)
        let box = ink(thread)
        #expect(abs(box.minX - 34.33) < 0.5)
        #expect(abs(box.maxX - 70.33) < 0.5)
        #expect(abs(box.minY - 708.3) < 1.5, "starts at the quote's bottom (707.3)")
        #expect(abs(box.maxY - 744.0) < 0.7, "the arm at the reply's middle (740.3-744.0)")
    }

    @Test func theirReplyToTheirMessageIsAStraightLineBetweenThem() {
        let quote = CGRect(x: 20, y: 0, width: 200, height: 29)
        let reply = CGRect(x: 20, y: 41, width: 160, height: 44)
        let thread = Thread.row(quote: quote, quoteSide: .leading, reply: reply, replySide: .leading, columnX: column)
        let box = thread.path.boundingBoxOfPath
        #expect(box.width < 0.01, "a straight line")
        #expect(box.minY > quote.maxY && box.maxY < reply.minY, "between the two bubbles, touching neither")
    }

    @Test func aShortBracketKeepsItsTwoCornersApart() {
        let quote = CGRect(x: 300, y: 0, width: 120, height: 29)
        let reply = CGRect(x: 300, y: 33, width: 120, height: 20)
        let thread = Thread.row(quote: quote, quoteSide: .trailing, reply: reply, replySide: .trailing, columnX: column)
        #expect(thread.radius <= (thread.bottom.y - thread.top.y) / 2 + 0.001)
        #expect(thread.path.boundingBoxOfPath.height > 0)
    }

    @Test func aGroupReplyStopsAboveTheRepliersAvatar() {
        let quote = CGRect(x: 59, y: 0, width: 200, height: 29)
        let reply = CGRect(x: 59, y: 50, width: 160, height: 44)
        let thread = Thread.row(quote: quote, quoteSide: .leading, reply: reply, replySide: .leading, columnX: 36, replyAvatarTop: 62)
        #expect(thread.columnX == 36)
        #expect(thread.bottom == .cap(y: 50 - Thread.replyGap), "the bubble is higher than the avatar")
    }
}
