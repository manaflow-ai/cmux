import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// A Chief's bare URL opens on a click (Lawrence 2026-10-23: the Cloud Chief's
/// `**https://github.com/login/device**` was bold text no click opened). A real `ChatController`
/// over a loaded conversation in an offscreen window: a click on the bold bare URL and one on a
/// Markdown link each open their page (`onOpenLink`). The window's picture, with a red ring at
/// each clicked point, is `.build/chief-links-click.png` (a fleet step returns it with `--artifact`).
@MainActor @Suite(.serialized) struct HomeBareLinkClickTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let device = "https://github.com/login/device"
    static let pr = "https://github.com/manaflow-ai/cmux/pull/1"
    static let text = "Sign in to GitHub: copy the code `ABCD-1234`, then open **\(device)** and approve.\nThe change is [PR 1](\(pr)); see also https://github.com/manaflow-ai/cmux."

    private func controller() -> (NSWindow, ChatController) {
        _ = NSApplication.shared
        HomeMarkdownPolicy.install()
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Cloud Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: chief, parts: [.text(Self.text)],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_1"))]
        let summary = ConversationSummary(id: ConversationID("conv_links"), title: "Cloud Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_links"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 560, height: 360)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        return (window, controller)
    }

    /// The first point (scan order) whose link is `url`.
    private func point(in controller: ChatController, opening url: String) -> CGPoint? {
        let b = controller.host.bounds
        for y in stride(from: b.minY, to: b.maxY, by: 2) {
            for x in stride(from: b.minX, to: b.maxX, by: 2) {
                let p = CGPoint(x: x, y: y)
                guard controller.demo?.hit(p) != nil else { continue }
                if controller.linkURL(at: p)?.absoluteString == url { return p }
            }
        }
        return nil
    }

    @Test func aClickOnABoldBareURLAndOnAMarkdownLinkOpensEachPage() throws {
        let (window, controller) = controller()
        var opened: [String] = []
        controller.onOpenLink = { url, _ in opened.append(url.absoluteString) }
        var clicks: [CGPoint] = []
        for url in [Self.device, Self.pr] {
            let p = try #require(point(in: controller, opening: url), "no point opens \(url)")
            let hit = try #require(controller.demo?.hit(p))
            #expect(controller.openLink(hit, at: p))
            clicks.append(p)
        }
        #expect(opened == [Self.device, Self.pr])
        try capture(controller.host, rings: clicks)
        withExtendedLifetime(window) {}
    }

    /// The host's picture with a ring at each point, at `.build/chief-links-click.png`.
    private func capture(_ view: NSView, rings: [CGPoint]) throws {
        CATransaction.flush()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let shot = try #require(rep.cgImage)
        let scale = CGFloat(shot.width) / view.bounds.width
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: shot.width, height: shot.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
        ctx.setLineWidth(2 * scale)
        for p in rings {
            // View points are flipped (origin top left) when the view is; the bitmap's origin is bottom left.
            let y = view.isFlipped ? view.bounds.height - p.y : p.y
            ctx.strokeEllipse(in: CGRect(x: (p.x - 9) * scale, y: (y - 9) * scale, width: 18 * scale, height: 18 * scale))
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/chief-links-click.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
