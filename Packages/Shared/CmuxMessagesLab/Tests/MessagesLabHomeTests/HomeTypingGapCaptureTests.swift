import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The picture of the typing bubble under the Chief's newest bubble (user 2026-10-30: "we need more space in
/// between typing bubble and the latest message", then "maybe even more padding"): before (8 pt body to body) and
/// after, dark and light, in
/// `.build/home-typing-gap.png` (a fleet step returns it with `--artifact`). The bubble above draws through
/// `RowDraw`; the typing bubble, its tail discs and dots are layers on macOS (RowCell), so this draws them from
/// the same geometry (`RowDraw.typingBubble`, `.typingDiscs`, `.typingDotCenter`). `HomeTypingGapTests` checks the gap.
@MainActor @Suite(.serialized) struct HomeTypingGapCaptureTests {
    static let text = "a878 confirmed its design doc is on feat-cmux-next, so it's finished. I opened the doc on the right."

    func rows(before: Bool) -> [RowSpec] {
        var m = HomeTypingGapTests.message("m1", "chief", at: 0)
        m.parts = [.text(Self.text, runs: [])]
        let s = HomeTypingGapTests.state([m])
        var rows = Fixture.withRenderScale(2) {
            RowBuilder.rows(s, messages: s.conversation.messages, now: HomeTypingGapTests.t0.addingTimeInterval(30), width: 360, scale: 2)
        }.filter { $0.key != "notice" && !$0.key.hasPrefix("sep:") }
        if before, let i = rows.firstIndex(where: { $0.key == "typing" }) { rows[i].gap = 8 - (RowDraw.typingBubble.minY - RowDraw.margin) }
        return rows
    }

    func render(light: Bool, before: Bool) -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let scale: CGFloat = 2, width: CGFloat = 360
        let specs = rows(before: before)
        let height = specs.reduce(CGFloat(32)) { $0 + $1.total }
        guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        var y: CGFloat = 16
        for spec in specs {
            y += spec.gap
            if case .typing = spec.kind {
                drawTyping(ctx, rowTop: y, height: height, scale: scale)
            } else {
                let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
                if let image = Fixture.withRenderScale(2, { WideBitmap.make(size: size, scale: scale, opaque: false) { RowDraw.drawStatic(spec, $0, windowY: .nan) } }) {
                    let top = y - RowDraw.margin
                    ctx.draw(image, in: CGRect(x: 0, y: (height - top - size.height) * scale, width: size.width * scale, height: size.height * scale))
                }
            }
            y += spec.height
        }
        return ctx.makeImage()
    }

    /// The typing bubble at rest in row coordinates (`RowDraw` rects carry the bitmap margin above the row).
    func drawTyping(_ ctx: CGContext, rowTop: CGFloat, height: CGFloat, scale: CGFloat) {
        let colors = Fixture.typingColors(inactive: false)
        func flip(_ r: CGRect) -> CGRect {
            let top = rowTop + r.minY - RowDraw.margin
            return CGRect(x: r.minX * scale, y: (height - top - r.height) * scale, width: r.width * scale, height: r.height * scale)
        }
        ctx.setFillColor(colors.fill.cgColor)
        let b = flip(RowDraw.typingBubble)
        ctx.addPath(CGPath(roundedRect: b, cornerWidth: b.height / 2, cornerHeight: b.height / 2, transform: nil))
        ctx.fillPath()
        for d in RowDraw.typingDiscs { ctx.fillEllipse(in: flip(d)) }
        ctx.setFillColor(colors.dotLit.cgColor)
        for i in 0..<3 {
            let c = RowDraw.typingDotCenter(i)
            ctx.fillEllipse(in: flip(CGRect(x: c.x - 3.25, y: c.y - 3.25, width: 6.5, height: 6.5)))
        }
    }

    @Test func theTypingGapBeforeAndAfterDarkAndLight() throws {
        let shots = try [false, true].flatMap { light in try [true, false].map { before in try #require(render(light: light, before: before)) } }
        let gap = 40
        let w = shots.prefix(2).reduce(gap) { $0 + $1.width }, h = 2 * (shots.map(\.height).max() ?? 0) + gap
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { Issue.record("no context"); return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Rows: dark, light. Columns: before, after.
        for (i, shot) in shots.enumerated() {
            let x = (i % 2) * (shots[0].width + gap), top = (i / 2) * (h + gap) / 2
            ctx.draw(shot, in: CGRect(x: x, y: h - top - shot.height, width: shot.width, height: shot.height))
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-typing-gap.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
