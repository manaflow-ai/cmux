import CoreGraphics

/// The thread line that joins an inline reply's quote to the reply, as
/// Messages draws it: it drops from under the quoted bubble's tail (or, in a
/// group, the avatar column beside the quote) and, when the reply sits on
/// the other side of the transcript, turns toward it in a short curve level
/// with the reply's middle. It never starts beside the quote or crosses it.
/// Top-left-origin coordinates, the cell's.
public struct ConversationReplyThread: Equatable, Sendable {
    /// The quoted bubble's body (its tail drops `quoteTailDrop` below it).
    public var quoteBody: CGRect
    /// The side the quoted message was sent from (its tail's side).
    public var quoteSide: ConversationBubbleGeometry.Side
    public var quoteTailDrop: CGFloat
    /// The reply's bubble (or its first piece of content).
    public var reply: CGRect
    public var replySide: ConversationBubbleGeometry.Side
    /// A group's avatar column center for an incoming quote; nil threads
    /// under the quote's own tail.
    public var column: CGFloat?
    /// Where a line on the reply's own side stops (a group reply's avatar
    /// top); nil stops just above the reply.
    public var stopY: CGFloat?

    /// How far in from the quote's body edge the line drops (under the tail).
    public static let tailInset: CGFloat = 6
    /// Space between the line and what it leaves or meets.
    public static let gap: CGFloat = 3
    /// The turn toward a reply on the other side.
    public static let turnRadius: CGFloat = 12

    public init(
        quoteBody: CGRect,
        quoteSide: ConversationBubbleGeometry.Side,
        quoteTailDrop: CGFloat,
        reply: CGRect,
        replySide: ConversationBubbleGeometry.Side,
        column: CGFloat? = nil,
        stopY: CGFloat? = nil
    ) {
        self.quoteBody = quoteBody
        self.quoteSide = quoteSide
        self.quoteTailDrop = quoteTailDrop
        self.reply = reply
        self.replySide = replySide
        self.column = column
        self.stopY = stopY
    }

    /// The thread for one transcript row. `avatarColumnCenter` is the
    /// center of a group's avatar column; `replyAvatarTop` the top of an
    /// incoming group reply's avatar.
    public static func row(
        quoteBody: CGRect,
        quoteSide: ConversationBubbleGeometry.Side,
        quoteTailDrop: CGFloat,
        reply: CGRect,
        replySide: ConversationBubbleGeometry.Side,
        isGroup: Bool,
        avatarColumnCenter: CGFloat,
        replyAvatarTop: CGFloat?
    ) -> ConversationReplyThread {
        ConversationReplyThread(
            quoteBody: quoteBody, quoteSide: quoteSide, quoteTailDrop: quoteTailDrop,
            reply: reply, replySide: replySide,
            column: avatarColumnCenter,
            stopY: replyAvatarTop.map { $0 - 6 }
        )
    }

    /// The x the line drops along.
    public var columnX: CGFloat {
        column ?? (quoteSide == .leading ? quoteBody.minX + Self.tailInset : quoteBody.maxX - Self.tailInset)
    }

    /// The line's top: under the quote and its tail.
    public var startY: CGFloat {
        quoteBody.maxY + (column == nil ? quoteTailDrop : 0) + Self.gap
    }

    /// The line's bottom: level with the reply's middle when it turns toward
    /// a reply on the other side, else just above the reply (or `stopY`).
    public var endY: CGFloat {
        let end = turnsTowardReply ? reply.midY : (stopY ?? reply.minY - Self.gap)
        return max(startY + 1, end)
    }

    /// The reply sits on the other side: the line ends in a turn toward it.
    public var turnsTowardReply: Bool { quoteSide != replySide }

    public var path: CGPath {
        // Base behavior: starts beside the quote at its middle.
        let x = column ?? quoteBody.minX
        let path = CGMutablePath()
        let quoteBodyLeading = quoteBody.minX
        path.move(to: CGPoint(x: min(quoteBodyLeading - 4, x + 14), y: quoteBody.midY))
        path.addQuadCurve(to: CGPoint(x: x, y: quoteBody.midY + 14), control: CGPoint(x: x, y: quoteBody.midY))
        if replySide == .trailing || stopY == nil {
            let endY = max(quoteBody.midY + 28, reply.midY)
            path.addLine(to: CGPoint(x: x, y: endY - 14))
            path.addQuadCurve(to: CGPoint(x: x + 14, y: endY), control: CGPoint(x: x, y: endY))
        } else {
            path.addLine(to: CGPoint(x: x, y: max(quoteBody.midY + 16, stopY ?? reply.maxY)))
        }
        return path
    }
}
