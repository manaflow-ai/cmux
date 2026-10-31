import AppKit
import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The before/after picture of other people replying to other people in a group (user, 2026-10-29, a macOS Messages
/// group chat as the target): the user's scene (Lucas and Austin, a text root, a link card root, a 3-line root and two
/// replies further down), its rows drawn by `RowDraw` over the transcript background, dark and light at 529 pt side by
/// side in `.build/home-group-reply.png` (a fleet step returns it with `--artifact`). It checks only that both drew;
/// `HomeGroupReplyQuoteTests` checks the geometry.
@MainActor @Suite(.serialized) struct HomeGroupReplyCaptureTests {
    static let me = ParticipantID("user_me")
    static let lucas = ParticipantID("user_lucas")
    static let austin = ParticipantID("user_austin")
    static let id = ConversationID("conv_group_capture")
    static let width: CGFloat = 529

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    static func rows() -> [RowSpec] {
        let summary = ConversationSummary(
            id: id,
            participants: [
                CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                CmuxHomeCore.Participant(id: lucas, kind: .human, displayName: "Lucas Ribeiro"),
                CmuxHomeCore.Participant(id: austin, kind: .human, displayName: "Austin Wang"),
            ],
            lastSeq: 7, createdAt: date(-100), updatedAt: date(0))
        let long = MessageID("msg_long"), link = MessageID("msg_link")
        func item(_ seq: Int, _ author: ParticipantID, _ text: String, _ id: MessageID? = nil, replyTo: MessageID? = nil) -> TranscriptItem {
            TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: Seq(seq), author: author, parts: [.text(text)], createdAt: date(Double(seq) * 70),
                           delivery: .committed, replyTo: replyTo.map { PartRef(message: $0) }, threadRoot: replyTo,
                           messageID: id ?? MessageID("msg_\(seq)"))
        }
        let items = [
            item(1, lucas, "Oh great!"),
            item(2, austin, "Also: Update to freestyle@0.2.21 there's a new customer field. The more fields you can give us, the more we can "
                 + "fingerprint and protect accounts from each other. The api doesn't have this field yet, so don't ship it quite yet.", long),
            item(3, lucas, "I also came across this the other day"),
            item(4, lucas, "https://boat.dev", link),
            item(5, austin, "we do want to tag these vms"),
            item(6, austin, "Haha", replyTo: link),
            item(7, lucas, "Is this for me to do or just a sidenote", replyTo: long),
        ]
        var core = ProjectionCore(me: me)
        let (conv, _) = core.install(id, items: items, summary: summary)
        return Fixture.withRenderScale(2) {
            RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: date(600), width: width, scale: 2)
        }
    }

    func render(light: Bool) throws -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let rows = Self.rows()
        let height = rows.reduce(CGFloat(24)) { $0 + $1.total }
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(Self.width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        var y: CGFloat = 0
        for spec in rows {
            y += spec.gap
            let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
            if let image = Fixture.withRenderScale(2, { WideBitmap.make(size: size, scale: scale, opaque: false) { RowDraw.drawStatic(spec, $0, windowY: .nan) } }) {
                // CG's origin is the bottom left: the row's content top (`margin` into its bitmap) goes `y` under the top.
                let top = y - RowDraw.margin
                ctx.draw(image, in: CGRect(x: 0, y: (height - top - size.height) * scale, width: size.width * scale, height: size.height * scale))
            }
            y += spec.height
        }
        return ctx.makeImage()
    }

    @Test func otherPeoplesRepliesDarkAndLight() throws {
        let dark = try #require(try render(light: false))
        let light = try #require(try render(light: true))
        let gap = 40
        guard let ctx = CGContext(data: nil, width: dark.width + gap + light.width, height: max(dark.height, light.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(dark, in: CGRect(x: 0, y: ctx.height - dark.height, width: dark.width, height: dark.height))
        ctx.draw(light, in: CGRect(x: dark.width + gap, y: ctx.height - light.height, width: light.width, height: light.height))
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-group-reply.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
