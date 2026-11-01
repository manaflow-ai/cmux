import AppKit
@testable import CmuxHomeCore
import Foundation
import ImageIO
import Testing
@testable import MessagesLabHome

/// A long message's "Show all N lines" band (Lawrence 2026-10-21: "show all button doesnt work",
/// a 203-line message in Home). The real view over a real `HomeStore` (`HomeChatRig`): a click on
/// the band expands the message, a click on its "Show less" band folds it again, and no line of
/// the hidden middle draws behind the band.
@MainActor @Suite(.serialized) struct HomeLongTextBandTests {
    static let lines = 203

    private func longText() -> String {
        (1...Self.lines).map { "\(HomeChatRig.tag) line \($0) Hgjpqy" }.joined(separator: "\n")
    }

    /// The long message's cell and its band in the transcript view's coordinates (the click space).
    private func band(_ r: HomeChatRig) -> (cell: RowCell, body: TiledBody, rect: CGRect)? {
        guard let demo = r.view.controller.demo else { return nil }
        for case let cell as RowCell in demo.collection.visibleCells {
            guard let t = cell.tiled, t.bandShown else { continue }
            return (cell, t, cell.convert(t.bandRect, to: demo))
        }
        return nil
    }

    private func messageID(_ r: HomeChatRig) -> ID? {
        guard let demo = r.view.controller.demo else { return nil }
        for case let cell as RowCell in demo.collection.visibleCells {
            if cell.tiled != nil, let spec = cell.spec, case let .part(p) = spec.kind { return p.ref.messageId }
        }
        return nil
    }

    @Test func clickingTheBandExpandsAndShowLessFoldsAgain() async throws {
        let r = try await HomeChatRig(history: 4)
        defer { r.stop() }
        await r.send(longText())
        for _ in 0..<4 { r.frame() }
        let folded = try #require(band(r), "the long message shows its band")
        #expect(folded.body.folded, "a 203-line message folds")
        #expect(folded.body.bandLabel == LongTextFold.label(Self.lines))
        let id = try #require(messageID(r))

        r.view.controller.clicked(CGPoint(x: folded.rect.midX, y: folded.rect.midY))
        for _ in 0..<4 { r.frame() }
        #expect(LongTextFold.isExpanded(id), "a click on Show all expands the message")

        // The Show less band is after the last line: bring it into view and click it.
        let demo = try #require(r.view.controller.demo)
        demo.setOffset(demo.pinnedOffset)
        for _ in 0..<4 { r.frame() }
        let less = try #require(band(r), "the expanded message shows Show less")
        #expect(!less.body.folded)
        #expect(less.body.bandLabel == LongTextFold.lessLabel)
        r.view.controller.clicked(CGPoint(x: less.rect.midX, y: less.rect.midY))
        for _ in 0..<4 { r.frame() }
        #expect(!LongTextFold.isExpanded(id), "a click on Show less folds the message again")
    }

    /// The pane as drawn (folded, then expanded by a click on the band) into
    /// `.build/long-text-band-shots.zip`, the before/after pictures of the fix.
    @Test func foldedAndExpandedRenderToTheShots() async throws {
        _ = NSApplication.shared
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/long-text-band-shots", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = try await HomeChatRig(history: 4)
        defer { r.stop() }
        await r.send(longText())
        try await settle(r)
        let folded = try #require(band(r))
        try write(render(r), to: out.appendingPathComponent("1-folded.png"))
        r.view.controller.clicked(CGPoint(x: folded.rect.midX, y: folded.rect.midY))
        try await settle(r)
        try write(render(r), to: out.appendingPathComponent("2-expanded.png"))
        let id = try #require(messageID(r))
        #expect(LongTextFold.isExpanded(id))
        LongTextFold.collapse(id)
        let zip = package.appendingPathComponent(".build/long-text-band-shots.zip")
        try? FileManager.default.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", out.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
    }

    /// Frames until the tile queue has drawn the visible tiles (an offscreen window has no display link).
    private func settle(_ r: HomeChatRig) async throws {
        for _ in 0..<12 {
            r.frame()
            // Justification: the tile queue draws off main; a bounded wait lets its tiles land (shots only).
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func render(_ r: HomeChatRig) throws -> CGImage {
        let view = r.view
        let layer = try #require(view.layer)
        let scale: CGFloat = 2, size = view.bounds.size
        let ctx = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        return try #require(ctx.makeImage())
    }

    private func write(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func noHiddenLineDrawsBehindTheBand() async throws {
        let r = try await HomeChatRig(history: 4)
        defer { r.stop() }
        await r.send(longText())
        for _ in 0..<4 { r.frame() }
        let b = try #require(band(r))
        #expect(b.body.folded)
        // The head shows lines 1...40 and the tail the last 40: the clips stop at the band's
        // edges, so the 41st line's tops and the line before the tail never show under the label.
        let shown = b.body.bandRect
        #expect(b.body.headClip.frame.maxY <= shown.minY, "head clip \(b.body.headClip.frame) reaches into the band \(shown)")
        #expect(b.body.tailClip.frame.minY >= shown.maxY, "tail clip \(b.body.tailClip.frame) reaches into the band \(shown)")
    }
}
