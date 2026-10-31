import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Lawrence's scrawl capture of 2026-10-29 (DEV invite-base-v1, no words, six clicks on the thread
/// preview "for imessage ui make sure we handle other people responding to other people / 3 Replies"):
/// each click on the preview flipped Home between the transcript and the thread view. The first click
/// opened the thread. The thread view moves its rows (the root goes up under the header), so the spot
/// the person had just clicked was then the blurred backdrop, and the next click on it closed the view.
/// The click after that opened it again. In Messages, a click on the opener again does not close the
/// thread: the view opens once and stays. The real view over a real `HomeStore` (`HomeChatRig`); clicks
/// go through the pane's click path (`ChatController.clicked`).
@MainActor @Suite(.serialized) struct HomeThreadReclickTests {
    /// The root (mine) with three Chief replies in its thread; the transcript shows its preview.
    private func threadRig() async throws -> HomeChatRig {
        let r = try await HomeChatRig(history: 6)
        let rootText = "\(HomeChatRig.tag) for imessage ui make sure we handle other people responding to other people"
        await r.send(rootText)
        await HomeChatRig.until { [store = r.store] in
            store.transcript(for: HomeChatRig.conversation).contains { $0.plainText == rootText && $0.messageID != nil }
        }
        let root = try #require(r.store.transcript(for: HomeChatRig.conversation).first { $0.plainText == rootText }?.messageID)
        for n in 1...3 {
            #expect(await r.post([.text("\(HomeChatRig.tag) reply \(n)")], key: IdempotencyKey("reclick-reply-\(n)"), threadRoot: root))
        }
        for _ in 0..<4 { r.frame() }
        return r
    }

    /// The first point (newest row first, as `debugOpenNewestThread` scans) that opens a thread.
    private func openerPoint(_ demo: MessagesWindowView) throws -> CGPoint {
        let cells = demo.collection.visibleCells.compactMap { $0 as? RowCell }
            .map { $0.convert($0.bounds, to: demo) }.sorted { $0.maxY > $1.maxY }
        for r in cells {
            for y in stride(from: r.maxY, to: r.minY, by: -3) {
                for x in stride(from: r.minX, to: r.maxX, by: 3) where demo.repliesHit(CGPoint(x: x, y: y)) != nil {
                    return CGPoint(x: x, y: y)
                }
            }
        }
        Issue.record("no thread preview or N Replies in the transcript")
        throw CancellationError()
    }

    @Test func clickingTheThreadOpenerAgainKeepsTheThreadOpenAndStill() async throws {
        let r = try await threadRig()
        defer { r.stop() }
        let demo = try #require(r.view.controller.demo)
        let p = try openerPoint(demo)

        r.view.controller.clicked(p)
        for _ in 0..<4 { r.frame() }
        let root = try #require(r.view.debugOpenThread, "the first click opens the thread")
        let rows = demo.threadViews.map(\.frame)
        let scroll = r.view.controller.host.scrollView.contentView.bounds.origin.y

        // The capture's clicks: the same spot, again and again.
        for click in 2...5 {
            r.view.controller.clicked(p)
            for _ in 0..<4 { r.frame() }
            #expect(r.view.debugOpenThread == root, "click \(click) on the opener's spot closed the thread")
            #expect(demo.threadViews.map(\.frame) == rows, "click \(click) moved the thread's rows")
            #expect(r.view.controller.host.scrollView.contentView.bounds.origin.y == scroll, "click \(click) scrolled the transcript")
        }
    }

    @Test func clickingTheBackdropAwayFromTheOpenerStillClosesTheThread() async throws {
        let r = try await threadRig()
        defer { r.stop() }
        let demo = try #require(r.view.controller.demo)
        let p = try openerPoint(demo)
        r.view.controller.clicked(p)
        for _ in 0..<4 { r.frame() }
        try #require(r.view.debugOpenThread != nil)

        // A backdrop point off the thread's rows and off the opener's row.
        let opener = try #require(demo.collection.visibleCells.compactMap { $0 as? RowCell }
            .map { $0.convert($0.bounds, to: demo) }.first { $0.contains(p) })
        let area = demo.threadArea
        var away: CGPoint?
        search: for y in stride(from: area.minY + 4, to: area.maxY, by: 6) {
            for x in [area.minX + 12, area.maxX - 12] {
                let q = CGPoint(x: x, y: y)
                if !demo.threadContentContains(q), !opener.contains(q) { away = q; break search }
            }
        }
        r.view.controller.clicked(try #require(away, "no backdrop point found"))
        for _ in 0..<4 { r.frame() }
        #expect(r.view.debugOpenThread == nil, "a backdrop click away from the opener closes the thread")
    }

    /// The capture's five clicks on the opener as a filmstrip (`.build/home-thread-reclick.png`; a fleet step
    /// returns it with `--artifact`): the transcript, then the view after each click. It checks only that it
    /// drew, so the same test gives the before picture on a commit without the fix. The blur filter does not
    /// draw offscreen, so the transcript under the thread shows sharp.
    @Test func theReclickFilmstrip() async throws {
        let r = try await threadRig()
        defer { r.stop() }
        let demo = try #require(r.view.controller.demo)
        let p = try openerPoint(demo)
        let size = r.view.bounds.size
        func shot() -> CGImage? {
            guard let layer = r.view.layer,
                  let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            if layer.isGeometryFlipped || r.view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
            layer.render(in: ctx)
            // The click: a red ring at `p`.
            ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24))
            return ctx.makeImage()
        }
        var frames: [CGImage] = []
        if let f = shot() { frames.append(f) }
        for _ in 1...5 {
            r.view.controller.clicked(p)
            for _ in 0..<30 { r.frame() }
            if let f = shot() { frames.append(f) }
        }
        #expect(frames.count == 6)
        let fw = Int(size.width), fh = Int(size.height), gap = 8
        guard let sheet = CGContext(data: nil, width: frames.count * fw + (frames.count - 1) * gap, height: fh, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        sheet.setFillColor(CGColor(gray: 0.5, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height))
        for (i, f) in frames.enumerated() { sheet.draw(f, in: CGRect(x: i * (fw + gap), y: 0, width: fw, height: fh)) }
        let image = try #require(sheet.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-thread-reclick.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
