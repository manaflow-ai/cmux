import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// User, Oct 28: "this reply ui is still bad", with a macOS 27 Messages screenshot as the target
/// (docs/design/home-reply-imessage-parity.md has the measurements, 2x, dark). In Messages the
/// quoted root above a reply is small: 10 pt text, 23.5 pt tall for one line, a 1 pt outline in a
/// dim blue (#38608B) with its own tail, "N Replies" 11 pt in from the quote's right end, 14 pt
/// under it, and the reply on the other side hangs from the quote on a grey arc. Home drew a
/// 12 pt, 28 pt tall pill in full blue, no tail, no arc.
@MainActor @Suite(.serialized) struct HomeReplyQuoteParityTests {
    // MARK: Drawing

    struct Bitmap {
        var data: [UInt8]
        var width: Int, height: Int
        func rgb(_ p: CGPoint) -> (Double, Double, Double) {
            let x = min(width - 1, max(0, Int(p.x * 2))), y = min(height - 1, max(0, Int(p.y * 2)))
            let i = (y * width + x) * 4
            return (Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
        }
    }

    static let canvas = CGSize(width: 700, height: 120)
    static let top: CGFloat = 20
    static let width: CGFloat = 628
    static let short = "top left wisdom teeth area started to hurt today"

    private func srgb(_ c: NSColor) -> (Double, Double, Double) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (Double(s.redComponent * 255), Double(s.greenComponent * 255), Double(s.blueComponent * 255))
    }

    private func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    private func preview(_ text: String = short, count: Int = 3) -> ThreadPreview {
        Fixture.withRenderScale(2) {
            ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []), count: count,
                               outgoing: true, width: Self.width)
        }
    }

    /// My quote drawn as the transcript draws it, dark, at 2x in sRGB.
    private func render(_ pv: ThreadPreview) -> (Bitmap, CGRect) {
        Fixture.withRenderScale(2) {
            let w = Int(Self.canvas.width * 2), h = Int(Self.canvas.height * 2)
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let rightEdge = Metrics(width: Self.width).rightEdge
            let box = CGRect(x: rightEdge - pv.box.width, y: Self.top, width: pv.box.width, height: pv.box.height)
            data.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 2, y: -2)
                ContextScope.run(ctx) {
                    Fixture.background.setFill()
                    ctx.fill(CGRect(origin: .zero, size: Self.canvas))
                    PartRenderer.drawOutgoingThreadPreview(ctx, pv, top: Self.top, rightEdge: rightEdge)
                }
            }
            return (Bitmap(data: data, width: w, height: h), box)
        }
    }

    /// The pixels in `r` (pt) whose colour is within `tolerance` of `c`.
    private func hits(_ bmp: Bitmap, _ r: CGRect, near c: (Double, Double, Double), tolerance: Double) -> [CGPoint] {
        var out: [CGPoint] = []
        var y = r.minY
        while y < r.maxY {
            var x = r.minX
            while x < r.maxX { if distance(bmp.rgb(CGPoint(x: x, y: y)), c) <= tolerance { out.append(CGPoint(x: x, y: y)) }; x += 0.5 }
            y += 0.5
        }
        return out
    }

    @Test func aOneLineQuoteIsMessagesSize() {
        let pv = preview()
        #expect(ThreadPreview.textFont.pointSize == 10, "quote text is \(ThreadPreview.textFont.pointSize) pt; Messages draws 10 pt")
        #expect(pv.box.height == 23.5, "a one-line quote is \(pv.box.height) pt tall; Messages' is 23.5 pt")
        let two = preview(String(repeating: "does apple watch have feature that detects when u fall asleep ", count: 2))
        #expect(two.box.height == 34.5, "a two-line quote is \(two.box.height) pt tall; Messages' is 34.5 pt (11 pt line pitch)")
    }

    /// User, Oct 28 (second screenshot): a wrapped quote left a wide empty band right of its text. Messages' quote hugs
    /// its widest line (2-line reference: line 1 ends 12 pt before the quote's right end, the outline + 9 pt pad), at every
    /// transcript width.
    @Test(arguments: [CGFloat(420), 628, 1000, 1600])
    func aWrappedQuoteHugsItsWidestLine(width: CGFloat) {
        let text = "make sure the highlight color across everything in the app can be customized (and is consistent) based on the user's terminal theme"
        let pv = Fixture.withRenderScale(2) {
            ThreadPreview.make(root: PartRef(messageId: "root", partIndex: 0), part: .text(text, runs: []), count: 2,
                               outgoing: true, width: width)
        }
        let widest = pv.textLines.map { TextDraw.width($0, font: ThreadPreview.textFont) }.max() ?? 0
        let slack = pv.box.width - ThreadPreview.textPadX - widest
        #expect(slack >= -0.01 && slack <= 1, "at \(width) pt the quote is \(pv.box.width) pt for a \(widest) pt line: \(slack) pt of empty space")
    }

    @Test func myQuoteIsOutlinedInMessagesDimBlue() {
        let (bmp, box) = render(preview())
        let edge = bmp.rgb(CGPoint(x: box.minX + 0.5, y: box.midY))
        #expect(distance(edge, (56, 96, 139)) <= 16, "my quote's outline is \(edge); Messages' is (56, 96, 139)")
        let bg = srgb(Fixture.background)
        let inside = bmp.rgb(CGPoint(x: box.minX + 3, y: box.midY))
        #expect(distance(inside, bg) <= 12, "my quote is filled \(inside); it should be an outline")
    }

    @Test func myQuoteHasAnOutlinedTail() {
        let (bmp, box) = render(preview())
        // Messages: the tail's outline hangs 4 pt under the quote's bottom, 5 to 12 pt in from its right end.
        let tail = hits(bmp, CGRect(x: box.maxX - 13, y: box.maxY + 1.5, width: 12, height: 3), near: (56, 96, 139), tolerance: 30)
        #expect(!tail.isEmpty, "no tail outline under my quote's right end")
    }

    @Test func repliesLabelSitsWhereMessagesPutsIt() throws {
        let (bmp, box) = render(preview(count: 3))
        let tint = srgb(Fixture.repliesTint)
        let label = hits(bmp, CGRect(x: box.maxX - 80, y: box.maxY + 2, width: 80, height: 18), near: tint, tolerance: 40)
        let right = try #require(label.map(\.x).max())
        // Messages: the label's ink ends 11 pt left of the quote's right end ("3 Replies", 2x: 1282 vs 1304 px).
        #expect(abs((box.maxX - right) - 11) <= 1.5, "the label ends \(box.maxX - right) pt left of the quote's end; Messages: 11 pt")
        // Its baseline ("3" and "R" bottoms, the label's left 13 pt; the "p" descends) 14 pt under the quote.
        let left = try #require(label.map(\.x).min())
        let caps = label.filter { $0.x < left + 13 }.map(\.y).max() ?? 0
        #expect(abs((caps - box.maxY) - 13.75) <= 1, "the label's baseline is \(caps - box.maxY) pt under the quote; Messages: 14 pt")
    }

    // MARK: Layout

    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_quote_parity")
    static let root = MessageID("msg_root")
    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }
    static let summary = ConversationSummary(
        id: id,
        participants: [
            CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
        ],
        lastSeq: 3, createdAt: date(-100), updatedAt: date(0))

    /// My root, another message of mine, then the Chief's reply to the root: the reply gets a quote of the root.
    static func rows() -> [RowSpec] {
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: me, parts: [.text(short)], createdAt: date(2),
                           delivery: .committed, messageID: root),
            TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: me, parts: [.text("it might be wisdom teeth idk")],
                           createdAt: date(3), delivery: .committed, messageID: MessageID("msg_other")),
            TranscriptItem(key: IdempotencyKey("k3"), seq: 3, author: chief, parts: [.text("Could be, but where it hurts alone can't tell us.")],
                           createdAt: date(4), delivery: .committed, replyTo: PartRef(message: root), threadRoot: root,
                           messageID: MessageID("msg_reply")),
        ]
        var core = ProjectionCore(me: me)
        let (conv, _) = core.install(id, items: items, summary: summary)
        return Fixture.withRenderScale(2) {
            RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: date(60), width: width, scale: 2)
        }
    }

    @Test func theChiefsReplyHangsFromMyQuoteOnAnArc() throws {
        let rows = Self.rows()
        let quote = try #require(rows.first { if case .threadPreview = $0.kind { true } else { false } })
        let reply = try #require(rows.last { if case .part = $0.kind { true } else { false } })
        guard case let .part(p) = reply.kind else { throw CancellationError() }
        #expect(p.connectorRoot == quote.key, "the Chief's reply under my quote draws no arc (connectorRoot \(String(describing: p.connectorRoot)))")
        // The arc's level: 2 pt under the quote's middle (Messages: 13.75 pt under a 23.5 pt quote's top).
        guard case let .threadPreview(pv) = quote.kind else { throw CancellationError() }
        #expect(abs(quote.connectorAnchorY - (pv.box.height / 2 + 2)) < 0.01)
    }

    @Test func theReplySits48AndAHalfPointsUnderTheQuoteTop() throws {
        let rows = Self.rows()
        var tops: [String: CGFloat] = [:], y: CGFloat = 0
        for r in rows { y += r.gap; tops[r.key] = y; y += r.height }
        let quote = try #require(rows.first { if case .threadPreview = $0.kind { true } else { false } })
        let reply = try #require(rows.last { if case .part = $0.kind { true } else { false } })
        let d = try #require(tops[reply.key]) - (try #require(tops[quote.key]))
        #expect(abs(d - 48.5) <= 0.5, "the reply is \(d) pt under the quote's top; Messages: 48.5 pt")
    }
}
