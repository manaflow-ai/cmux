import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The before/after picture of the reply thread line (refs/imessage-layout/1.png): the real Home
/// view over the mock owner, my message with a long block, a list and the question as three
/// bubbles, and the Chief's thread reply to it, drawn at 420 and 760 pt side by side in
/// `.build/home-reply-connector.png` (a fleet step returns it with `--artifact`). It checks only
/// that both drew; the picture is for people. `HomeReplyConnectorLengthTests` checks the length.
@MainActor @Suite(.serialized) struct HomeReplyConnectorCaptureTests {
    static let root = MessageID("msg_capture_root")

    func render(width: CGFloat) async throws -> CGImage? {
        let rig = try await HomeChatRig(history: 0, width: width)
        defer { rig.stop() }
        let conversation = HomeChatRig.conversation
        let block = (1...14).map { "Context line \($0) from the Chief." }.joined(separator: "\n")
        let models = ["Claude Fable 5.1", "Claude Opus 5.5", "Claude Sonnet 5.5", "Claude Haiku 5.5"].joined(separator: "\n")
        func post(_ id: MessageID, author: ParticipantID, parts: [CmuxHomeCore.MessagePart], replyTo: CmuxHomeCore.PartRef? = nil, root: MessageID? = nil) throws {
            let summary = try #require(rig.store.summary(conversation))
            let rev = rig.store.mirror.revision(of: .conversation(conversation)) + 1
            rig.store.handle(.message(CmuxHomeCore.Message(id: id, conversation: conversation, seq: summary.lastSeq + 1,
                                                           clientMessageID: IdempotencyKey(id.rawValue), author: author, parts: parts,
                                                           createdAt: Date(), replyTo: replyTo, threadRoot: root), rev: rev))
        }
        try post(Self.root, author: rig.me, parts: [.text(block), .text(models),
                                                     .text("optimize downloading update sizes, is that possible?")])
        try post(MessageID("msg_capture_reply"), author: rig.chief,
                 parts: [.text("Yes, it's possible. Sparkle can ship binary deltas, so an update downloads only what changed.")],
                 replyTo: CmuxHomeCore.PartRef(message: Self.root), root: Self.root)
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
        // The view's layers are y-down (a flipped NSView); a bitmap context is y-up.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    @Test func theThreadLineAtTwoWidths() async throws {
        let narrow = try #require(try await render(width: 420))
        let wide = try #require(try await render(width: 760))
        let gap = 40
        guard let ctx = CGContext(data: nil, width: narrow.width + gap + wide.width, height: max(narrow.height, wide.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.draw(narrow, in: CGRect(x: 0, y: ctx.height - narrow.height, width: narrow.width, height: narrow.height))
        ctx.draw(wide, in: CGRect(x: narrow.width + gap, y: ctx.height - wide.height, width: wide.width, height: wide.height))
        let image = try #require(ctx.makeImage())
        // The package directory: this file is Tests/MessagesLabHomeTests/<name>.swift.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-reply-connector.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
