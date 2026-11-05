import AppKit
import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The before/after picture of two bots talking in one Chief chat through their owner's CLI
/// (u20190, Nov 3): Grok bot › Ada asks, Muse and Claude Code answer, the Chief closes. Before, each
/// message was the owner's own blue bubble with a `[from …]` label in it; after, each bot is its
/// own run with its name and its brand mark or monogram. Drawn by `RowDraw` at 420 pt, before and
/// after side by side, dark over light, in `.build/home-agent-senders.png` (a fleet step returns it
/// with `--artifact`). It checks only that both drew; `HomeAgentSenderTests` checks the mapping.
@MainActor @Suite(.serialized) struct HomeAgentSenderCaptureTests {
    typealias G = HomeGroupSenderTests
    static let width: CGFloat = 420

    static let lines: [(key: String, author: ParticipantID, text: String)] = [
        ("agent~grok-bot.ada~question~~n1", G.me, "[from Grok bot › Ada] Muse, can you take the review of the sender PR?"),
        ("agent~muse~result~~n2", G.me, "[from Muse] Yes, on it. I will post the findings here."),
        ("agent~claude-3fa9c1d2@mini~result~~n3", G.me, "[from Claude Code › 3fa9c1d2@mini] Tests are green on the fleet."),
        ("k4", G.chief, "Thanks, all three. I will land it."),
    ]

    /// The rows of the scene; `before`: as the transcript drew it before u20190 (the bots' messages
    /// were the owner's own, label and all).
    static func rows(before: Bool) -> [RowSpec] {
        let items = lines.enumerated().map { i, line in
            TranscriptItem(key: IdempotencyKey(before ? "k\(i)" : line.key), seq: Seq(i + 1), author: line.author,
                           parts: [.text(line.text)], createdAt: G.date(Double(i) * 70), delivery: .committed,
                           messageID: MessageID("msg_\(i)"))
        }
        var core = ProjectionCore(me: G.me)
        let (conv, _) = core.install(G.id, items: items, summary: G.summary([G.me, G.chief]))
        return Fixture.withRenderScale(2) {
            RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: G.date(600), width: width, scale: 2)
        }
    }

    func render(before: Bool, light: Bool) -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let rows = Self.rows(before: before)
        let height = rows.reduce(CGFloat(24)) { $0 + $1.total }
        let scale: CGFloat = 2
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(Self.width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        var y: CGFloat = 0
        for spec in rows {
            y += spec.gap
            let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
            if let image = Fixture.withRenderScale(2, { WideBitmap.make(size: size, scale: scale, opaque: false) { RowDraw.drawStatic(spec, $0, windowY: .nan) } }) {
                let top = y - RowDraw.margin
                ctx.draw(image, in: CGRect(x: 0, y: (height - top - size.height) * scale, width: size.width * scale, height: size.height * scale))
            }
            y += spec.height
        }
        return ctx.makeImage()
    }

    @Test func twoBotsInOneChiefChatBeforeAndAfter() throws {
        let tiles = try [false, true].map { light in
            try [true, false].map { before in try #require(render(before: before, light: light)) }
        }
        let gap = 40
        let width = tiles.map { $0.reduce(0) { $0 + $1.width } + gap }.max() ?? 0
        let height = tiles.reduce(0) { $0 + ($1.map(\.height).max() ?? 0) } + gap
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var top = height
        for row in tiles {
            var x = 0
            let rowHeight = row.map(\.height).max() ?? 0
            for tile in row {
                ctx.draw(tile, in: CGRect(x: x, y: top - tile.height, width: tile.width, height: tile.height))
                x += tile.width + gap
            }
            top -= rowHeight + gap
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-agent-senders.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
