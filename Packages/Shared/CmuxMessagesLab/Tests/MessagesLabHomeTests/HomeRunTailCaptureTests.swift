import AppKit
import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The before/after picture of one sender's run (user, 2026-11-04, Home's welcome next to the same text in Messages:
/// only the last bubble has the tail): Chief's three welcome bubbles, then my two replies, drawn by `RowDraw` at 529 pt,
/// dark and light side by side in `.build/home-run-tail.png` (a fleet step returns it with `--artifact`). It checks only
/// that both drew; `HomeRunTailTests` checks the tails and gaps.
@MainActor @Suite(.serialized) struct HomeRunTailCaptureTests {
    static let me = ParticipantID("user_local")
    static let chief = ParticipantID("agent_mux")
    static let id = ConversationID("conv_run_tail_capture")
    static let width: CGFloat = 529

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    static func rows() -> [RowSpec] {
        let summary = ConversationSummary(
            id: id,
            participants: [
                CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
            ],
            lastSeq: 5, createdAt: date(-100), updatedAt: date(0))
        func item(_ seq: Int, _ key: String, _ author: ParticipantID, _ text: String) -> TranscriptItem {
            TranscriptItem(key: IdempotencyKey(key), seq: Seq(seq), author: author, parts: [.text(text)], createdAt: date(Double(seq) * 5),
                           delivery: .committed, messageID: MessageID("msg_\(seq)"))
        }
        let items = [
            item(1, "chief-welcome-hello-v2", chief, "Welcome to cmux! 👋 I'm Chief."),
            item(2, "chief-welcome-about-v2", chief, "I can make new workspaces, start agents for you, and set up or customize cmux however you like.\n"
                 + "Just tell me what you want done."),
            item(3, "chief-welcome-background-v1", chief, "Want to make it yours? Pick a background from the built-in art or one of your own pictures. "
                 + "Or skip it and just say hi."),
            item(4, "k4", me, "hi"),
            item(5, "k5", me, "what can you do?"),
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

    @Test func oneTailPerRunDarkAndLight() throws {
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
        let out = package.appendingPathComponent(".build/home-run-tail.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
