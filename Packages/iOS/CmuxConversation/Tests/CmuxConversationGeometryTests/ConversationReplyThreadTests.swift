import CoreGraphics
import Testing
@testable import CmuxConversationGeometry

/// The inline reply's thread line, as Messages draws it (iOS 14 to 26
/// screenshots): it drops from under the quoted bubble (its tail, or a
/// group's avatar column) and turns toward a reply on the other side. It
/// never starts beside the quote at its middle, which drew a hook out of
/// the quote's side and through its tail (Chief, 2026-10-21).
@Suite struct ConversationReplyThreadTests {
    typealias Thread = ConversationReplyThread
    let tailDrop: CGFloat = 6.8

    /// A 440 pt phone, 20 pt margins, 32 pt avatars.
    func row(
        quote: CGRect, quoteSide: ConversationBubbleGeometry.Side,
        reply: CGRect, replySide: ConversationBubbleGeometry.Side,
        isGroup: Bool = false, replyAvatarTop: CGFloat? = nil
    ) -> Thread {
        Thread.row(quoteBody: quote, quoteSide: quoteSide, quoteTailDrop: tailDrop,
                   reply: reply, replySide: replySide, isGroup: isGroup,
                   avatarColumnCenter: 36, replyAvatarTop: replyAvatarTop)
    }

    @Test func aOneToOneReplyThreadsFromUnderTheQuotesTailTowardTheReply() {
        // "u sure?" (outgoing) replying to Chief's message (incoming).
        let quote = CGRect(x: 20, y: 0, width: 280, height: 34)
        let reply = CGRect(x: 330, y: 47, width: 90, height: 36)
        let thread = row(quote: quote, quoteSide: .leading, reply: reply, replySide: .trailing)
        let box = thread.path.boundingBoxOfPath
        #expect(box.minY >= quote.maxY + tailDrop, "the line starts under the quote and its tail")
        #expect(box.minX >= quote.minX, "nothing sticks out of the quote's leading side")
        #expect(box.maxX < reply.minX, "the turn points at the reply without reaching it")
        #expect(thread.path.currentPoint.y == reply.midY)
        #expect(thread.path.currentPoint.x > thread.columnX)
    }

    @Test func aReplyToAnOutgoingQuoteThreadsDownTheTrailingSide() {
        // Chief (incoming) replying to my message (outgoing quote).
        let quote = CGRect(x: 240, y: 0, width: 180, height: 34)
        let reply = CGRect(x: 20, y: 47, width: 200, height: 36)
        let thread = row(quote: quote, quoteSide: .trailing, reply: reply, replySide: .leading)
        let box = thread.path.boundingBoxOfPath
        #expect(box.minY >= quote.maxY + tailDrop)
        #expect(box.minX >= quote.minX)
        #expect(box.maxX <= quote.maxX)
        #expect(thread.path.currentPoint.x < thread.columnX, "turns toward the reply on the leading side")
        #expect(thread.path.currentPoint.y == reply.midY)
    }

    @Test func aSameSideReplyGetsAStraightLineThatStopsAboveIt() {
        let quote = CGRect(x: 20, y: 0, width: 200, height: 34)
        // The row's own spacing: the tail, the 6 pt small space, and the straight run's room.
        let reply = CGRect(x: 20, y: 34 + tailDrop + 6 + Thread.minimumStraightRun, width: 160, height: 36)
        let thread = row(quote: quote, quoteSide: .leading, reply: reply, replySide: .leading)
        let box = thread.path.boundingBoxOfPath
        #expect(box.width < 0.01)
        #expect(box.minY >= quote.maxY + tailDrop)
        #expect(box.maxY <= reply.minY)
        #expect(box.height >= 10, "a visible line, not a dot")
    }

    @Test func aGroupReplyThreadsDownTheAvatarColumnToTheRepliersAvatar() {
        // Incoming group rows: avatar column centered at 36, bubbles at 59.
        let quote = CGRect(x: 59, y: 0, width: 200, height: 34)
        let reply = CGRect(x: 59, y: 60, width: 160, height: 36)
        let thread = row(quote: quote, quoteSide: .leading, reply: reply, replySide: .leading,
                         isGroup: true, replyAvatarTop: 64)
        let box = thread.path.boundingBoxOfPath
        #expect(box.width < 0.01)
        #expect(box.minX == 36)
        #expect(box.minY >= quote.maxY)
        #expect(box.maxY == 58)
    }

    @Test func aGroupOutgoingReplyTurnsOutOfTheAvatarColumn() {
        let quote = CGRect(x: 59, y: 0, width: 200, height: 34)
        let reply = CGRect(x: 330, y: 47, width: 90, height: 36)
        let thread = row(quote: quote, quoteSide: .leading, reply: reply, replySide: .trailing, isGroup: true)
        let box = thread.path.boundingBoxOfPath
        #expect(box.minX == 36)
        #expect(box.minY >= quote.maxY)
        #expect(thread.path.currentPoint == CGPoint(x: 56, y: reply.midY))
    }

    @Test func aReplyRightUnderTheQuoteStillDrawsDownward() {
        let quote = CGRect(x: 20, y: 0, width: 200, height: 34)
        let reply = CGRect(x: 330, y: 36, width: 90, height: 10)
        let thread = row(quote: quote, quoteSide: .leading, reply: reply, replySide: .trailing)
        #expect(thread.endY > thread.startY)
        #expect(thread.path.boundingBoxOfPath.minY >= quote.maxY)
    }
}
