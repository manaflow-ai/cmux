import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Lawrence, 2026-11-23 (a screen recording of a Chief reply thread open over the dimmed chat): "notice how clicking
/// some parts fails to close it". The spot where the thread's opener (its "N Replies" or its preview quote) lay in the
/// transcript kept every later click for as long as the view was open. The view moves its rows, so a date line or the
/// space beside a bubble sat over that spot, and clicks there did nothing (the opener band of 65de6042205f, 2026-10-29,
/// narrowed to the opener's width in bfa920dd77b1, 2026-11-07; a preview quote is as wide as its message). Only the
/// second press of the double-click that opened the thread belongs to the opener; a later click there is on the
/// backdrop and closes the view. The real view over a real `HomeStore` (`HomeChatRig`); clicks go through the pane's
/// click path (`ChatController.clicked`).
@MainActor @Suite(.serialized) struct HomeThreadOpenerSpotTests {
    /// The root (mine) with three Chief replies in its thread; the transcript shows its preview.
    private func threadRig() async throws -> HomeChatRig {
        let r = try await HomeChatRig(history: 6)
        let rootText = "\(HomeChatRig.tag) also u should check all my browser profiles before asking me to enter the codes or whatever"
        await r.send(rootText)
        await HomeChatRig.until { [store = r.store] in
            store.transcript(for: HomeChatRig.conversation).contains { $0.plainText == rootText && $0.messageID != nil }
        }
        let root = try #require(r.store.transcript(for: HomeChatRig.conversation).first { $0.plainText == rootText }?.messageID)
        for n in 1...3 {
            #expect(await r.post([.text("\(HomeChatRig.tag) profiles reply \(n)")], key: IdempotencyKey("opener-spot-reply-\(n)"), threadRoot: root))
        }
        for _ in 0..<4 { r.frame() }
        return r
    }

    /// The thread opener: its first point (newest row first) and the band of its row that opens the thread.
    private func opener(_ demo: MessagesWindowView) throws -> (point: CGPoint, band: CGRect) {
        let cells = demo.collection.visibleCells.compactMap { $0 as? RowCell }
            .map { $0.convert($0.bounds, to: demo) }.sorted { $0.maxY > $1.maxY }
        for r in cells {
            for y in stride(from: r.maxY, to: r.minY, by: -3) {
                let xs = stride(from: r.minX, to: r.maxX, by: 2).filter { demo.repliesHit(CGPoint(x: $0, y: y)) != nil }
                if let lo = xs.first, let hi = xs.last {
                    return (CGPoint(x: lo, y: y), CGRect(x: lo - 2, y: r.minY, width: hi - lo + 4, height: r.height))
                }
            }
        }
        Issue.record("no thread preview or N Replies in the transcript")
        throw CancellationError()
    }

    private func open(_ r: HomeChatRig, at p: CGPoint) throws {
        if r.view.debugOpenThread == nil { r.view.controller.clicked(p) }
        for _ in 0..<4 { r.frame() }
        try #require(r.view.debugOpenThread != nil, "the opener did not open the thread")
    }

    /// Points of the opener's band that the open view leaves as backdrop (no bubble, control or message box there).
    private func backdropSpots(_ demo: MessagesWindowView, point p: CGPoint, band: CGRect) -> [(String, CGPoint)] {
        let field = demo.compose.fieldRect.insetBy(dx: -60, dy: -8)
        var spots: [(String, CGPoint)] = [("on the opener's own spot", p)]
        for y in stride(from: band.minY + 2, to: band.maxY, by: 4) {
            for x in [band.minX + 3, band.midX, band.maxX - 3] {
                spots.append(("in the opener's band", CGPoint(x: x, y: y)))
            }
        }
        return spots.filter { _, q in !demo.threadContentHit(q) && !field.contains(q) && demo.bounds.contains(q) }
    }

    @Test func aLaterClickWhereTheOpenerLayClosesTheThread() async throws {
        let r = try await threadRig()
        defer { r.stop() }
        let demo = try #require(r.view.controller.demo)
        let (p, band) = try opener(demo)
        try open(r, at: p)
        let spots = backdropSpots(demo, point: p, band: band)
        try #require(spots.count >= 3, "too few backdrop spots in the opener's band: \(spots.count)")
        var kept: [CGPoint] = []
        for (_, spot) in spots {
            try open(r, at: p)
            r.view.controller.clicked(spot)
            for _ in 0..<4 { r.frame() }
            if r.view.debugOpenThread != nil { kept.append(spot) }
        }
        #expect(kept.isEmpty, "\(kept.count) of \(spots.count) backdrop clicks where the opener lay kept the thread open: \(kept.prefix(6))")
    }

    /// The bug as three frames (`.build/home-thread-opener-spot.png`; a fleet step returns it with `--artifact`): the
    /// transcript with the opener click, the open thread with a later click on the backdrop where the opener lay, then
    /// the result (before the fix the thread stays open, after it the transcript is back). It checks only that it drew,
    /// so the same test gives the before picture on a commit without the fix. The blur filter does not draw offscreen,
    /// so the transcript under the thread shows sharp.
    @Test func theOpenerSpotFilmstrip() async throws {
        let r = try await threadRig()
        defer { r.stop() }
        let demo = try #require(r.view.controller.demo)
        let (p, band) = try opener(demo)
        let size = r.view.bounds.size
        func shot(ring q: CGPoint?) -> CGImage? {
            guard let layer = r.view.layer,
                  let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            if layer.isGeometryFlipped || r.view.isFlipped { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
            layer.render(in: ctx)
            if let q {
                ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
                ctx.setLineWidth(3)
                ctx.strokeEllipse(in: CGRect(x: q.x - 12, y: q.y - 12, width: 24, height: 24))
            }
            return ctx.makeImage()
        }
        var frames: [CGImage] = []
        if let f = shot(ring: p) { frames.append(f) }
        try open(r, at: p)
        for _ in 0..<30 { r.frame() }
        let spot = try #require(backdropSpots(demo, point: p, band: band).first?.1, "no backdrop spot in the opener's band")
        if let f = shot(ring: spot) { frames.append(f) }
        r.view.controller.clicked(spot)
        for _ in 0..<30 { r.frame() }
        if let f = shot(ring: nil) { frames.append(f) }
        #expect(frames.count == 3)
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
        let out = package.appendingPathComponent(".build/home-thread-opener-spot.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
