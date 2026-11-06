import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing
import UniformTypeIdentifiers

/// The before/after picture of a1017's chat in the agent pane (user 2026-11-05, msg 23140): the Chief spawned it behind
/// the cap 6 min 50 s ago and told it more while it waited. Drawn dark and light into
/// `.build/home-agent-chat-queued.png` (a fleet step returns it with `--artifact`). It checks only that both drew;
/// `HomeAgentPaneTests` checks the words.
@MainActor @Suite(.serialized) struct HomeAgentChatCaptureTests {
    /// What the Chief's projection gives a1017 here: Queued since the fix (Working before it).
    static let state: HomeAgentMessageRow.PeerState = .queued

    func render(light: Bool) throws -> NSBitmapImageRep {
        let start = Date(timeIntervalSince1970: 1_000)
        let thread = HomeAgentThread(
            peer: "a1017", title: "Chief teleport indicator", state: Self.state,
            task: "Title: Chief teleport indicator\n\nUser (msg 23114/23120): asked to verify teleporting the Chief to cloud, and \"i want to see chat indicator\".",
            entries: [.init(id: "t2", outgoing: true, text: "Add to your scope: the Home \"Teleport Chief\" picker must update too.",
                            date: start.addingTimeInterval(60))],
            startedAt: start, endedAt: nil, newestReportAt: nil, workspaceLink: nil)
        let chat = HomeAgentChatView(content: HomeAgentChatContent(thread, now: start.addingTimeInterval(410)),
                                     actions: .init(sent: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let box = NSBox(frame: NSRect(x: 0, y: 0, width: 520, height: 560))
        box.boxType = .custom
        box.fillColor = .windowBackgroundColor
        box.borderWidth = 0
        chat.frame = box.bounds
        chat.autoresizingMask = [.width, .height]
        box.addSubview(chat)
        window.contentView = box
        box.layoutSubtreeIfNeeded()
        let rep = try #require(box.bitmapImageRepForCachingDisplay(in: box.bounds))
        box.cacheDisplay(in: box.bounds, to: rep)
        return rep
    }

    @Test func aQueuedAgentsChatDarkAndLight() throws {
        let reps = try [false, true].map { try render(light: $0) }
        let images = reps.compactMap(\.cgImage)
        #expect(images.count == 2)
        let gap = 40
        guard let ctx = CGContext(data: nil, width: images.map(\.width).reduce(0, +) + gap, height: images.map(\.height).max() ?? 0,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
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
        let out = package.appendingPathComponent(".build/home-agent-chat-queued.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
