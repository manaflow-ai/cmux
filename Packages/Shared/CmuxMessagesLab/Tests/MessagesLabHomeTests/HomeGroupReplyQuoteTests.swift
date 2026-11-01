import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// User, Oct 29 (NIGHTLY, a macOS Messages group chat with Lucas Ribeiro and Austin Wang as the target): "make sure we
/// handle other people responding to other people". When Austin replies to Lucas's message further up, Messages
/// (2x reference, dark, `docs/design/home-group-reply-imessage-parity.md`):
/// - draws the quote of Lucas's message at the bubble column (not under the avatar column), outlined, at half opacity;
/// - draws Lucas's avatar small (18 pt) and at half opacity in the avatar column, its bottom 4 pt under the quote's;
/// - runs a 2.5 pt connector line from 6 pt under that avatar down the avatar column to the top of Austin's bubble;
/// - keeps Austin's name over his reply and his avatar beside it; his bubble's top is 35 pt under the quote's bottom;
/// - says "1 Reply" under Lucas's message when its one reply is further down.
/// Each case maps HomeStore items through `ProjectionCore`, derives rows with `RowBuilder` and draws them with `RowDraw`.
@MainActor @Suite(.serialized) struct HomeGroupReplyQuoteTests {
    static let me = ParticipantID("user_me")
    static let lucas = ParticipantID("user_lucas")
    static let austin = ParticipantID("user_austin")
    static let id = ConversationID("conv_group_reply")
    static let root = MessageID("msg_root")
    static let reply = MessageID("msg_reply")
    static let width: CGFloat = 628

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    static let summary = ConversationSummary(
        id: id,
        participants: [
            CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: lucas, kind: .human, displayName: "Lucas Ribeiro"),
            CmuxHomeCore.Participant(id: austin, kind: .human, displayName: "Austin Wang"),
        ],
        lastSeq: 4, createdAt: date(-100), updatedAt: date(0))

    static let short = "Oh great!"
    static let long = "Also: Update to freestyle@0.2.21 there's a new customer field. The more fields you can give us, the more we can "
        + "fingerprint and protect accounts from each other. The api doesn't have this field yet, so don't ship it quite yet."

    /// Lucas's root, two unrelated messages, then `replier`'s reply to the root (or, `adjacent`, the reply right under it).
    static func rows(root text: String = short, replier: ParticipantID = austin, adjacent: Bool = false) -> [RowSpec] {
        var items = [TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: lucas, parts: [.text(text)], createdAt: date(2),
                                    delivery: .committed, messageID: root)]
        if !adjacent {
            items.append(TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: lucas, parts: [.text("I also came across this the other day")],
                                        createdAt: date(70), delivery: .committed, messageID: MessageID("msg_2")))
            items.append(TranscriptItem(key: IdempotencyKey("k3"), seq: 3, author: austin, parts: [.text("we do want to tag these vms")],
                                        createdAt: date(140), delivery: .committed, messageID: MessageID("msg_3")))
        }
        items.append(TranscriptItem(key: IdempotencyKey("k4"), seq: 4, author: replier, parts: [.text("Is this for me to do or just a sidenote")],
                                    createdAt: date(210), delivery: .committed, replyTo: PartRef(message: root), threadRoot: root,
                                    messageID: reply))
        var core = ProjectionCore(me: me)
        let (conv, _) = core.install(id, items: items, summary: summary)
        return Fixture.withRenderScale(2) {
            RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: date(300), width: width, scale: 2)
        }
    }

    /// The reply's first bubble: the first part row under the quote.
    static func replyKey(_ rows: [RowSpec]) throws -> String {
        let q = try #require(rows.firstIndex { $0.key.hasPrefix("preview:") })
        return try #require(rows.dropFirst(q).first { if case .part = $0.kind { true } else { false } }).key
    }

    static func tops(_ rows: [RowSpec]) -> [String: CGFloat] {
        var tops: [String: CGFloat] = [:], y: CGFloat = 0
        for r in rows { y += r.gap; tops[r.key] = y; y += r.height }
        return tops
    }

    static func preview(_ rows: [RowSpec]) throws -> (RowSpec, ThreadPreview) {
        let row = try #require(rows.first { $0.key.hasPrefix("preview:") }, "no quote above the reply: \(rows.map(\.key))")
        guard case let .threadPreview(pv) = row.kind else { throw CancellationError() }
        return (row, pv)
    }

    /// A row drawn as the transcript draws it (`RowDraw.drawStatic`, transparent), 2 px a point, RGBA, top row first.
    /// Content top is `RowDraw.margin` down.
    struct Drawn {
        var pixels: [UInt8]
        var width: Int, height: Int
        func rgba(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
            let px = min(width - 1, max(0, Int(x * 2))), py = min(height - 1, max(0, Int((y + RowDraw.margin) * 2)))
            let i = (py * width + px) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), Double(pixels[i + 3]))
        }
        func alpha(_ x: CGFloat, _ y: CGFloat) -> Double { rgba(x, y).a }
    }

    static func draw(_ spec: RowSpec) throws -> Drawn {
        let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
        let image = try #require(Fixture.withRenderScale(2) {
            WideBitmap.make(size: size, scale: 2, opaque: false) { ctx in RowDraw.drawStatic(spec, ctx, windowY: .nan) }
        })
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Drawn(pixels: pixels, width: w, height: h)
    }

    static var bubbleColumn: CGFloat { Fixture.leftEdge + SenderAvatar.bubbleInset }
    static var avatarCenterX: CGFloat { SenderAvatar.left + SenderAvatar.diameter / 2 }

    @Test(arguments: [HomeGroupReplyQuoteTests.short, HomeGroupReplyQuoteTests.long])
    func theQuoteSitsAtTheBubbleColumnOutlined(root: String) throws {
        let (row, pv) = try Self.preview(Self.rows(root: root))
        let d = try Self.draw(row)
        let mid = pv.box.height / 2
        // Between the avatar column and the bubble column: nothing (the quote starts at the bubble column).
        #expect(d.alpha(Self.bubbleColumn - 4, mid) < 10, "the quote starts left of the bubble column")
        #expect(d.alpha(Self.bubbleColumn + 0.5, mid) > 10, "no outline at the bubble column")
        // Outlined, not filled: 3 pt in from the outline, before the text, is empty.
        #expect(d.alpha(Self.bubbleColumn + 3, mid) < 10, "the quote is filled; Messages outlines it")
    }

    @Test func theQuotedPersonsAvatarIsSmallAndFadedBesideTheQuote() throws {
        let (row, pv) = try Self.preview(Self.rows())
        let d = try Self.draw(row)
        // 18 pt, its bottom 4.25 pt under the quote's, centred on the avatar column.
        let bottom = pv.box.height + 4.25
        let centre = d.rgba(Self.avatarCenterX, bottom - 9)
        #expect(centre.a > 90 && centre.a < 170, "the quoted person's avatar is drawn at alpha \(centre.a); Messages: half")
        #expect(d.alpha(Self.avatarCenterX, bottom - 9 - 11) < 10, "the avatar is taller than 18 pt")
        #expect(d.alpha(Self.avatarCenterX + 11, bottom - 9) < 10, "the avatar is wider than 18 pt")
    }

    @Test(arguments: [HomeGroupReplyQuoteTests.short, HomeGroupReplyQuoteTests.long])
    func aLineRunsFromTheAvatarIntoTheReply(root: String) throws {
        let rows = Self.rows(root: root)
        let (row, pv) = try Self.preview(rows)
        let tops = Self.tops(rows)
        let quoteTop = try #require(tops[row.key])
        let replyTop = try #require(tops[try Self.replyKey(rows)])
        let d = try Self.draw(row)
        let lineTop = pv.box.height + 4.25 + 6.25
        let lineEnd = replyTop - quoteTop - 0.5
        let connector = Fixture.connector.usingColorSpace(.sRGB) ?? Fixture.connector
        for y in stride(from: lineTop + 1, through: lineEnd - 1, by: 2) {
            let p = d.rgba(Self.avatarCenterX, y)
            #expect(p.a > 200, "no line at \(y) pt (reply top \(replyTop - quoteTop) pt under the quote's top)")
            #expect(abs(p.r - Double(connector.redComponent * 255)) <= 12, "the line is \(p); Messages: the connector grey")
        }
        #expect(d.alpha(Self.avatarCenterX, lineTop - 2) < 10, "the line touches the avatar; Messages leaves 6 pt")
        // No 1:1 stub at x 32.5 beside it.
        #expect(d.alpha(33.75, pv.box.height + 6) < 10 || abs(33.75 - Self.avatarCenterX) < 2)
    }

    @Test func theReplyKeepsItsNameAndAvatar35PointsUnderTheQuote() throws {
        let rows = Self.rows()
        let (row, pv) = try Self.preview(rows)
        let keys = rows.map(\.key)
        let replyKey = try Self.replyKey(rows)
        let i = try #require(keys.firstIndex(of: replyKey))
        #expect(keys[i - 1].hasPrefix("name:") && rows[i - 1].kind == .senderName("Austin Wang"), "no name over the reply: \(keys)")
        guard case let .part(p) = rows[i].kind else { throw CancellationError() }
        #expect(p.cmuxAvatar != nil, "no avatar beside the reply")
        let tops = Self.tops(rows)
        let gap = try #require(tops[replyKey]) - (try #require(tops[row.key]) + pv.box.height)
        #expect(abs(gap - 35) <= 0.5, "the reply's top is \(gap) pt under the quote; Messages: 35 pt")
    }

    @Test func aRootWithOneReplyFurtherDownSaysOneReply() throws {
        let rows = Self.rows()
        let label = try #require(rows.first { $0.key.hasPrefix("replies:") }, "no \"1 Reply\" under the root: \(rows.map(\.key))")
        guard case let .replies(n, _, _) = label.kind else { throw CancellationError() }
        #expect(n == 1)
        // At the indented bubbles' label edge (Messages: 16 pt in from the bubble's left).
        let d = try Self.draw(label)
        let ink = (0..<Int(Self.bubbleColumn + 40)).map(CGFloat.init).first { x in
            stride(from: CGFloat(2), to: 20, by: 0.5).contains { d.alpha(x, $0) > 60 }
        }
        let left = try #require(ink)
        #expect(left >= Self.bubbleColumn + 8, "the label starts at \(left) pt, left of the indented bubbles' text")
        // A reply right under its root: the line shows the thread, no label.
        #expect(!Self.rows(adjacent: true).contains { $0.key.hasPrefix("replies:") })
    }

    @Test func aLinkCardQuoteIsOutlinedWithItsTail() throws {
        let (row, pv) = try Self.preview(Self.rows(root: "https://boat.dev"))
        guard case .link = pv.part else { Issue.record("the root https://boat.dev is not a link card: \(String(describing: pv.part))"); return }
        let d = try Self.draw(row)
        let right = Self.bubbleColumn + pv.box.width
        #expect(d.alpha(right - 0.5, pv.box.height / 2) > 10, "no outline at the card quote's right end")
        #expect(d.alpha(right - 4, pv.box.height / 2) < 10, "the card quote is filled; Messages outlines it")
        // Its tail hangs under the bottom-left, 5 to 12 pt in.
        let tail = stride(from: Self.bubbleColumn + 4, to: Self.bubbleColumn + 13, by: 0.5).contains { d.alpha($0, pv.box.height + 2) > 10 }
        #expect(tail, "no tail under the card quote's left end")
    }

    /// A group quote shows a multi-line root whole (user, 2026-10-30, "handle like multi-multi line"): this 230-character
    /// root wraps to 7 lines in the group quote's column at 628 pt, all shown, with no "…".
    @Test func aLongRootShowsEveryLine() throws {
        let (_, pv) = try Self.preview(Self.rows(root: Self.long + " " + Self.long))
        #expect(pv.textLines.count == 7, "the quote has \(pv.textLines.count) lines: \(pv.textLines)")
        #expect(pv.textLines.last?.hasSuffix("…") == false)
        #expect(pv.box.height == ThreadPreview.textHeight(lines: 7))
    }
}
