import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The before/after picture of user 2026-11-05 (msg 23140): three asks of mine, the Chief answering each in its thread,
/// a spawn that started a1016 and queued a1017 behind the cap, then a tell to the still-queued a1017. Drawn dark and
/// light, in a wide Home pane and a narrow docked-Chief one, into `.build/home-side-pane-polish.png` (a fleet step returns
/// it with `--artifact`). It checks only that each drew; the layout and state tests check the rules.
@MainActor @Suite(.serialized) struct HomeSidePanePolishCaptureTests {
    static let help = MessageID("msg_help"), indicator = MessageID("msg_indicator"), picker = MessageID("msg_picker")

    /// A spawn task or tell to `peer`; `queued`: it waits in the Chief's queue.
    static func tell(_ id: String, _ peer: String, _ text: String, at: Date, queued: Bool) -> HomeAgentRun.Message {
        HomeAgentRun.Message(id: id, sequence: 1, revision: 1, peer: peer, outgoing: true, text: text, date: at, queued: queued)
    }

    func render(light: Bool, width: CGFloat) async throws -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let rig = try await HomeChatRig(history: 0, width: width, height: 760)
        defer { rig.stop() }
        rig.window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let conversation = HomeChatRig.conversation
        let start = Date()
        var n = 0.0
        func post(_ id: MessageID, key: String? = nil, author: ParticipantID, _ text: String, replyTo: MessageID? = nil) throws {
            let summary = try #require(rig.store.summary(conversation))
            let rev = rig.store.mirror.revision(of: .conversation(conversation)) + 1
            n += 1
            rig.store.handle(.message(CmuxHomeCore.Message(id: id, conversation: conversation, seq: summary.lastSeq + 1,
                                                           clientMessageID: IdempotencyKey(key ?? id.rawValue), author: author, parts: [.text(text)],
                                                           createdAt: start.addingTimeInterval(n), replyTo: replyTo.map { CmuxHomeCore.PartRef(message: $0) },
                                                           threadRoot: replyTo), rev: rev))
        }
        func send(_ turn: String, _ hash: String, _ text: String, replyTo: MessageID) throws {
            try post(MessageID("msg_\(turn)_\(hash)"), key: "send-\(conversation.rawValue)-\(turn)-\(hash)", author: rig.chief, text, replyTo: replyTo)
        }
        try post(Self.help, author: rig.me, "help me fix")
        try post(Self.indicator, author: rig.me, "i want to see chat indicator that chief teleported where, when that does happen")
        try send("turn-0", "000000000000000a", "On it: a1016 names the models, a1017 adds the teleport indicator.", replyTo: Self.help)
        try post(Self.picker, author: rig.me, "this thing needs to update too perhaps")
        try send("turn-1", "000000000000000a", "Model picker names: a1016 makes full names readable. Queued until a slot frees up.", replyTo: Self.help)
        try send("turn-1", "000000000000000b", "Teleport, ~0%: the move to Cloud never ran. a1017 finds out why and fixes it.", replyTo: Self.indicator)
        try send("turn-1", "000000000000000c", "Agreed. I've added the Teleport picker to a1017's task.", replyTo: Self.picker)
        rig.store.applyAgentRun(HomeAgentRun(conversation: conversation, id: "run-0", author: rig.chief, turn: IdempotencyKey("turn-0"),
                                             answers: [Self.help], threadRoot: Self.help, revision: 1, messages: [
            Self.tell("spawn:a1016", "a1016", "Title: Model picker full names", at: start.addingTimeInterval(3), queued: false),
            Self.tell("spawn:a1017", "a1017", "Title: Chief teleport indicator", at: start.addingTimeInterval(3), queued: true),
        ]))
        rig.store.applyAgentRun(HomeAgentRun(conversation: conversation, id: "run-1", author: rig.chief, turn: IdempotencyKey("turn-1"),
                                             answers: [Self.picker], threadRoot: Self.picker, revision: 1, messages: [
            Self.tell("tell:a1017", "a1017", "Add to your scope: the Teleport picker.", at: start.addingTimeInterval(7), queued: true),
        ]))
        rig.view.controller.host.paneHeader.title = "Chief"
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

    @Test func homeAndDockDarkAndLight() async throws {
        var images: [CGImage] = []
        for width in [CGFloat(900), 420] {
            for light in [false, true] { images.append(try #require(try await render(light: light, width: width))) }
        }
        let gap = 40
        guard let ctx = CGContext(data: nil, width: images.map(\.width).reduce(0, +) + gap * (images.count - 1),
                                  height: images.map(\.height).max() ?? 0, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        var x = 0
        for image in images {
            ctx.draw(image, in: CGRect(x: x, y: ctx.height - image.height, width: image.width, height: image.height))
            x += image.width + gap
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-side-pane-polish.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
