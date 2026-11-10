import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// In a chat that shows senders (Home with the Chief's avatar, a group), everything under another person's run
/// starts at the bubbles' column, right of the avatar column (user 2026-11-09, msgs 26174 and 26176: "alignment
/// here is bad", "fewer, nicer dialogs pill needs to match leftness of the bubble"; then "double check all left
/// alignment here is good" over the activity line). The agent pills, a drawn table, the status line, the typing
/// bubble and the "Edited" label sat at `Fixture.leftEdge`, 28 pt left of the bubble they belong to, under the avatar.
@MainActor @Suite(.serialized) struct HomeGroupColumnAlignmentTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let me = "user_me", chief = "agent_chief"
    static let widths: [CGFloat] = [360, 560, 900]

    static func text(_ id: String, _ words: String, at seconds: Double, edited: Bool = false) -> MessagesLabHome.Message {
        MessagesLabHome.Message(id: id, senderId: chief, sentAt: Instant.format(t0.addingTimeInterval(seconds)),
                                parts: [.text(words, runs: [])], replyTo: nil, status: nil,
                                edits: edited ? [MessagesLabHome.Message.Edit(text: "before", at: Instant.format(t0))] : nil,
                                retractedAt: nil, reactions: [])
    }

    /// The Chief's agents row (one pill per agent), as Home maps it.
    static func pills(at seconds: Double) throws -> MessagesLabHome.Message {
        HomeAgentFoldRowProvider.install()
        var row = HomeAgentMessageRow(group: "0123456789abcdef", kind: .fold(count: 1, peers: ["a1076"], expanded: false))
        row.peerStates = [.told]
        row.peerTitles = ["Fewer, nicer dialogs"]
        let part = try #require(HomeAgentFoldRowProvider.part(row))
        return MessagesLabHome.Message(id: "pills", senderId: chief, sentAt: Instant.format(t0.addingTimeInterval(seconds)),
                                       parts: [part], replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    static func state(_ messages: [MessagesLabHome.Message], group: Bool = true) -> AppState {
        var conversation = Conversation(id: "c", title: "Chief", participants: [
            MessagesLabHome.Participant(id: me, displayName: "Me", isMe: true, avatar: nil),
            MessagesLabHome.Participant(id: chief, displayName: "Chief", isMe: false, avatar: .monogram("C")),
        ], messages: messages)
        if group { conversation.cmuxGroup = true }
        var s = AppState(conversation: conversation)
        s.total = messages.count
        return s
    }

    static func rows(_ s: AppState, width: CGFloat) -> [RowSpec] {
        RowBuilder.rows(s, messages: s.conversation.messages, now: t0.addingTimeInterval(30), width: width)
    }

    /// The text bubble's left edge (row coordinates) of message `id`.
    static func bubbleLeft(_ rows: [RowSpec], _ id: String) throws -> CGFloat {
        let row = try #require(rows.first { $0.key == "part:\(id):0" })
        return RowDraw.bodyRect(row).minX
    }

    /// The leftmost column (row coordinates, whole points) the row draws ink in, nil when it draws none.
    static func firstInk(_ spec: RowSpec) throws -> CGFloat? {
        let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
        let image = try #require(WideBitmap.make(size: size, scale: 1, opaque: false) { ctx in
            RowDraw.drawStatic(spec, ctx, windowY: .nan)
        })
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        #expect(drawn)
        for x in 0..<w {
            for y in 0..<h where pixels[(y * w + x) * 4 + 3] > 8 { return CGFloat(x) }
        }
        return nil
    }

    @Test(arguments: widths) func theAgentPillsStartAtTheBubblesLeftEdge(width: CGFloat) throws {
        let s = Self.state([Self.text("m1", "Cookie toast: a1076 is moving it", at: 0), try Self.pills(at: 1)])
        let rows = Self.rows(s, width: width)
        let bubble = try Self.bubbleLeft(rows, "m1")
        #expect(bubble == Fixture.leftEdge + SenderAvatar.bubbleInset)
        let pillsRow = try #require(rows.first { $0.key == "part:pills:0" })
        let body = RowDraw.bodyRect(pillsRow)
        #expect(body.minX == bubble, "the pills row starts at \(body.minX), the bubble at \(bubble)")
        // It ends where a full-width row ends: it does not run past the column's right edge.
        #expect(body.maxX <= pillsRow.metrics.rightEdge + 0.5, "the pills row ends at \(body.maxX), past \(pillsRow.metrics.rightEdge)")
        // And the first pill's own left edge is the bubble's.
        guard case let .part(p) = pillsRow.kind, case let .custom(custom) = p.part,
              let payload = HomeAgentFoldRowProvider.payload(custom) else { Issue.record("not a pills row"); return }
        let first = try #require(HomeAgentPills(payload, shape: .pill, width: body.width).pills.first)
        #expect(body.minX + first.rect.minX == bubble)
        // What is drawn: the pill's outline starts within a point of the bubble's edge (antialiasing).
        let drawnInk = try Self.firstInk(pillsRow)
        let ink = try #require(drawnInk)
        #expect(abs(ink - bubble) <= 1, "the pill draws from x \(ink), the bubble from \(bubble)")
    }

    /// The status line ("Sending a message › … · Telling an agent") heads the Chief's next bubble: its text starts a
    /// point in from the bubbles' column, as it does from the typing bubble's edge in a direct chat.
    @Test(arguments: widths) func theStatusLineStartsAtTheBubblesColumn(width: CGFloat) throws {
        var s = Self.state([Self.text("m1", "Cookie toast", at: 0)])
        s.ui.notice = "Sending a message\nTelling an agent"
        let rows = Self.rows(s, width: width)
        let bubble = try Self.bubbleLeft(rows, "m1")
        let notice = try #require(rows.first { $0.key == "notice" })
        // Its first glyph's ink (an "S") starts within 2 pt right of the line's left edge, a point in from the bubble's.
        let drawnInk = try Self.firstInk(notice)
        let ink = try #require(drawnInk)
        #expect(ink >= bubble && ink <= bubble + 3, "the status line draws from x \(ink), the bubble from \(bubble)")
    }

    /// The typing bubble moves to the bubbles' column with everything else.
    @Test func theTypingBubbleMovesToTheBubblesColumn() throws {
        var s = Self.state([Self.text("m1", "Cookie toast", at: 0)])
        s.ui.typing = [Self.chief]
        let rows = Self.rows(s, width: 560)
        let typing = try #require(rows.first { $0.key == "typing" })
        let bubble = try Self.bubbleLeft(rows, "m1")
        #expect(RowDraw.typingBubble.minX + typing.cmuxIndent == bubble)
    }

    /// "Edited" under the Chief's bubble lines up with the bubble's text, like the sender name above it.
    @Test func theEditedLabelLinesUpWithTheBubblesText() throws {
        let s = Self.state([Self.text("m1", "Cookie toast", at: 0, edited: true)])
        let rows = Self.rows(s, width: 560)
        let edited = try #require(rows.first { $0.key == "edited:m1" })
        let drawnInk = try Self.firstInk(edited)
        let ink = try #require(drawnInk)
        #expect(ink >= RowDraw.senderNameLeft - 1 && ink <= RowDraw.senderNameLeft + 2,
                "Edited draws from x \(ink), the bubble's text from \(RowDraw.senderNameLeft)")
    }

    /// A direct chat (no avatar column) keeps every row at the left edge.
    @Test func aDirectChatKeepsTheLeftEdge() throws {
        var s = Self.state([Self.text("m1", "Cookie toast", at: 0), try Self.pills(at: 1)], group: false)
        s.ui.notice = "Sending a message"
        let rows = Self.rows(s, width: 560)
        let textLeft = try Self.bubbleLeft(rows, "m1")
        let pillsLeft = try Self.bubbleLeft(rows, "pills")
        #expect(textLeft == Fixture.leftEdge)
        #expect(pillsLeft == Fixture.leftEdge)
        let notice = try #require(rows.first { $0.key == "notice" })
        let drawnInk = try Self.firstInk(notice)
        let ink = try #require(drawnInk)
        #expect(ink >= Fixture.leftEdge && ink <= Fixture.leftEdge + 3)
    }
}
