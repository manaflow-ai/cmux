import AppKit
import AVFoundation
import CmuxHomeCore
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// Lawrence 2026-10-05: a video plays inline in its bubble (iMessage-like):
/// a click plays or pauses in place (lane 16's VideoPlayback: an
/// AVPlayerLayer under the bubble's mask, the URL fetched only on play),
/// MessagesLab draws the poster and the play disc; opening the video in an
/// app is only in the context menu.
@MainActor @Suite(.serialized) struct VideoInlineTests {
    let them = Fixture2.them

    private func host() throws -> (NSWindow, HomeProjection, ChatController, MessagesLabHome.PartRef, Recorder) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let (p, c) = Fixture2.projection()
        c.host.frame = NSRect(x: 0, y: 0, width: 628, height: 900)
        window.contentView = c.host
        let poster = try AttachmentProjectionTests.png("poster.png", width: 640, height: 360)
        let asked = Recorder()
        p.media.fetch = { _, variant in
            await asked.add("\(variant)")
            return poster
        }
        let ref = AttachmentRef(hash: "h-clip", name: "clip.mov", mimeType: "video/quicktime", byteCount: 10, width: 640, height: 360,
                                durationMs: 2_000)
        let item = TranscriptItem(key: IdempotencyKey("vid"), seq: 4, author: them, parts: [.attachment(ref)],
                                  createdAt: Fixture2.start.addingTimeInterval(200), delivery: .committed, messageID: MessageID("m4"))
        p.apply(items: Fixture2.history(3) + [item], summary: Fixture2.summary(lastSeq: 4), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded()
        c.demo!.collection.layoutIfNeeded()
        return (window, p, c, MessagesLabHome.PartRef(messageId: "vid", partIndex: 0), asked)
    }

    /// The visible cell of a part row, and its bubble's centre in host coordinates.
    private func cell(_ c: ChatController, _ ref: MessagesLabHome.PartRef) throws -> (RowCell, CGPoint) {
        let cell = try #require(c.demo!.collection.visibleCells.compactMap { $0 as? RowCell }.first {
            if let spec = $0.spec, case let .part(p) = spec.kind { return p.ref == ref }
            return false
        })
        let body = RowDraw.bodyRect(cell.spec!)
        let p = cell.layer.convert(CGPoint(x: body.midX, y: body.midY), to: c.host.below.root)
        return (cell, p)
    }

    @Test func aClickPlaysTheVideoInItsBubbleAndAnotherPausesIt() async throws {
        let (window, p, c, ref, asked) = try host()
        defer { window.close() }
        let (cell, point) = try cell(c, ref)
        #expect(c.demo!.hit(point)?.row.ref == ref, "the click lands on the video bubble")
        c.clicked(point)
        #expect(p.videoState(ref) == .loading, "a click starts playback (fetching the URL)")
        await p.video.playback.settled()
        #expect(p.videoState(ref) == .playing)
        #expect(await asked.values.contains("original"), "the original is fetched only on play")
        let player = try #require(cell.layer.sublayers?.compactMap { $0 as? AVPlayerLayer }.first, "the player is in the bubble's cell")
        #expect(player.frame == RowDraw.bodyRect(cell.spec!), "the player covers the bubble")
        #expect(player.mask != nil, "under the bubble's mask")
        c.clicked(point)
        #expect(p.videoState(ref) == .paused, "a second click pauses in place")
        #expect(p.video.badgeVisible(ref), "the paused video shows MessagesLab's play disc")
    }

    @Test func openingInAnAppIsOnlyInTheContextMenu() async throws {
        let (window, p, c, ref, _) = try host()
        defer { window.close() }
        let (_, point) = try cell(c, ref)
        let menu = try #require(c.menu(at: point))
        let titles = menu.items.map { (item: NSMenuItem) in item.title }
        #expect(titles.contains("Play Video"))
        #expect(titles.contains("Open in Default App"))
        #expect(p.videoState(ref) == .poster, "the menu itself plays nothing")
    }
}
