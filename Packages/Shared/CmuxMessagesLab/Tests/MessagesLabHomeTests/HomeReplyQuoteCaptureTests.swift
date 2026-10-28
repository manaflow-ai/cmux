import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The before/after picture of the quote above a reply (user, Oct 28, against macOS 27 Messages):
/// the real Home view over the mock owner, my message, another of mine, then two Chief replies
/// to the first, so the reply gets the quote of my root with "2 Replies" and the arc. Drawn dark
/// and light at 628 pt side by side in `.build/home-reply-quote.png` (a fleet step returns it with
/// `--artifact`). It checks only that both drew; `HomeReplyQuoteParityTests` checks the geometry.
@MainActor @Suite(.serialized) struct HomeReplyQuoteCaptureTests {
    static let root = MessageID("msg_quote_root")

    func render(light: Bool) async throws -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let rig = try await HomeChatRig(history: 0, width: 628)
        defer { rig.stop() }
        let conversation = HomeChatRig.conversation
        func post(_ id: MessageID, author: ParticipantID, _ text: String, replyTo: MessageID? = nil) throws {
            let summary = try #require(rig.store.summary(conversation))
            let rev = rig.store.mirror.revision(of: .conversation(conversation)) + 1
            rig.store.handle(.message(CmuxHomeCore.Message(id: id, conversation: conversation, seq: summary.lastSeq + 1,
                                                           clientMessageID: IdempotencyKey(id.rawValue), author: author, parts: [.text(text)],
                                                           createdAt: Date(), replyTo: replyTo.map { CmuxHomeCore.PartRef(message: $0) },
                                                           threadRoot: replyTo), rev: rev))
        }
        try post(Self.root, author: rig.me, "top left wisdom teeth area started to hurt today")
        try post(MessageID("msg_quote_other"), author: rig.me, "it might be wisdom teeth idk")
        try post(MessageID("msg_quote_reply"), author: rig.chief,
                 "Could be, but where it hurts alone can't tell us whether it's a wisdom tooth, the gum around it, or another tooth.",
                 replyTo: Self.root)
        try post(MessageID("msg_quote_reply2"), author: rig.chief, "Any swelling or fever?", replyTo: Self.root)
        // Row bitmaps draw off main: give them a few frames.
        for _ in 0..<12 {
            rig.frame()
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let layer = rig.view.layer else { return nil }
        let scale: CGFloat = 2
        let size = rig.view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    @Test func theQuoteDarkAndLight() async throws {
        let dark = try #require(try await render(light: false))
        let light = try #require(try await render(light: true))
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
        let out = package.appendingPathComponent(".build/home-reply-quote.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
