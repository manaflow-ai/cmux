import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The Chief's tapbacks on my messages (Lawrence 2026-10-21, "chief needs to be able to send
/// reactions"; a416): the Chief's `react` tool commits `reaction.add` as the Chief, the owner
/// sends the message's update, and the real Home view (`MessagesLabHomeView` over a real
/// `HomeStore` on the mock owner) shows the badge on my bubble at once, with no reload: each
/// tapback kind and any emoji, on a message already shown, on a send still flying, and after
/// the Chief's next reply. `theBadgesInLightAndDark` draws the picture to
/// `.build/home-chief-reactions-{light,dark}.png` (a fleet step returns it with `--artifact`).
@MainActor @Suite(.serialized) struct HomeChiefReactionTests {
    /// The reactions the projection shows on my tagged message `text`: (sender, kind).
    static func shown(_ rig: HomeChatRig, on text: String) -> [(String, MessagesLabHome.Reaction.Kind)] {
        guard let s = rig.view.controller.store?.state else { return [] }
        let m = s.conversation.messages.first { m in
            m.parts.contains { if case let .text(t, _) = $0 { t == text } else { false } }
        }
        return (m?.reactions ?? []).map { ($0.senderId, $0.kind) }
    }

    static func messageID(_ rig: HomeChatRig, _ text: String) async -> MessageID? {
        await HomeChatRig.until { [store = rig.store] in
            store.transcript(for: HomeChatRig.conversation).contains { $0.plainText == text && $0.messageID != nil }
        }
        return rig.store.transcript(for: HomeChatRig.conversation).first { $0.plainText == text }?.messageID
    }

    /// Frames until the projection shows `count` reactions on `text` (a bounded wait: 200 frames).
    static func settle(_ rig: HomeChatRig, on text: String, count: Int) async {
        for _ in 0..<200 where shown(rig, on: text).count < count {
            rig.frame()
            await Task.yield()
        }
    }

    @Test func eachChiefTapbackShowsOnMyShownMessage() async throws {
        let rig = try await HomeChatRig(history: 4)
        defer { rig.stop() }
        let kinds: [(CmuxHomeCore.Reaction.Kind, MessagesLabHome.Reaction.Kind)] = [
            (.tapback(.like), .tapback("like")), (.tapback(.love), .tapback("love")), (.tapback(.laugh), .tapback("laugh")),
            (.tapback(.emphasize), .tapback("emphasize")), (.tapback(.question), .tapback("question")),
            (.tapback(.dislike), .tapback("dislike")), (.emoji("🔥"), .emoji("🔥")),
        ]
        for (i, (kind, expected)) in kinds.enumerated() {
            let text = "\(HomeChatRig.tag) message \(i)"
            #expect(await rig.send(text) == nil)
            let id = try #require(await Self.messageID(rig, text))
            for _ in 0..<5 { rig.frame(); await Task.yield() } // the send has landed in the projection
            #expect(await rig.source.react(kind, to: id, from: rig.chief, in: HomeChatRig.conversation))
            await Self.settle(rig, on: text, count: 1)
            let shown = Self.shown(rig, on: text)
            #expect(shown.count == 1 && shown.first?.0 == rig.chief.rawValue && shown.first?.1 == expected,
                    "the Chief's \(kind) shows on my bubble: \(shown)")
        }
    }

    @Test func aChiefTapbackOnASendStillFlyingShows() async throws {
        let rig = try await HomeChatRig(history: 4)
        defer { rig.stop() }
        let text = "\(HomeChatRig.tag) flying"
        #expect(await rig.send(text) == nil)
        let id = try #require(await Self.messageID(rig, text))
        // No frame between the commit and the Chief's tapback: both reach the view in one pass.
        #expect(await rig.source.react(.tapback(.like), to: id, from: rig.chief, in: HomeChatRig.conversation))
        await Self.settle(rig, on: text, count: 1)
        #expect(Self.shown(rig, on: text).map(\.0) == [rig.chief.rawValue])
    }

    @Test func theTapbackStaysAfterTheChiefReplies() async throws {
        let rig = try await HomeChatRig(history: 4)
        defer { rig.stop() }
        let text = "\(HomeChatRig.tag) keep it"
        #expect(await rig.send(text) == nil)
        let id = try #require(await Self.messageID(rig, text))
        for _ in 0..<5 { rig.frame(); await Task.yield() }
        #expect(await rig.source.react(.tapback(.like), to: id, from: rig.chief, in: HomeChatRig.conversation))
        await Self.settle(rig, on: text, count: 1)
        #expect(await rig.post("\(HomeChatRig.tag) on it", key: IdempotencyKey("run_keep")))
        for _ in 0..<20 { rig.frame(); await Task.yield() }
        #expect(Self.shown(rig, on: text).map(\.0) == [rig.chief.rawValue], "the reply does not take the badge away")
        // A replayed update (a reconnect's refetch) does not toggle it off.
        #expect(await rig.source.react(.tapback(.like), to: id, from: rig.chief, in: HomeChatRig.conversation))
        for _ in 0..<20 { rig.frame(); await Task.yield() }
        #expect(Self.shown(rig, on: text).map(\.0) == [rig.chief.rawValue], "a repeated update keeps one badge")
    }

    func render(dark: Bool) async throws -> CGImage? {
        let rig = try await HomeChatRig(history: 0, width: 520)
        defer { rig.stop() }
        rig.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let texts = ["\(HomeChatRig.tag) chief needs to be able to send reactions",
                     "\(HomeChatRig.tag) ship it", "\(HomeChatRig.tag) does the build pass?"]
        let kinds: [CmuxHomeCore.Reaction.Kind] = [.tapback(.like), .tapback(.love), .emoji("🔥")]
        for (text, kind) in zip(texts, kinds) {
            #expect(await rig.send(text) == nil)
            let id = try #require(await Self.messageID(rig, text))
            for _ in 0..<5 { rig.frame(); await Task.yield() }
            _ = await rig.source.react(kind, to: id, from: rig.chief, in: HomeChatRig.conversation)
            await Self.settle(rig, on: text, count: 1)
        }
        // Row bitmaps draw off main: give them a few frames (a bounded wait for the picture only).
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
        ctx.setFillColor(dark ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    @Test func theBadgesInLightAndDark() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for dark in [false, true] {
            let image = try #require(try await render(dark: dark))
            let out = package.appendingPathComponent(".build/home-chief-reactions-\(dark ? "dark" : "light").png")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
    }
}
