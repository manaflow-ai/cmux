import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The picture of the Chief's one-line status row over its typing dots (user 2026-10-29 9:01 PM:
/// "reading/starting agents should be one line"): the user's "Reading ›" + "Starting agents · 7s",
/// a three-part line, and a narrow column, each drawn by `RowDraw`, dark and light side by side in
/// `.build/home-status-line.png` (a fleet step returns it with `--artifact`). It checks only that
/// they drew; `HomeTurnProgressTests` checks the line.
@MainActor @Suite(.serialized) struct HomeStatusLineCaptureTests {
    static let notices: [(String, CGFloat)] = [
        ("Reading ›\nStarting agents · 7s", 529),
        ("Ran 3 commands · Read 2 files ›\nWaiting for a31's tests\nChecking on a31 · 2m 10s", 529),
        ("Ran 3 commands · Read 2 files ›\nWaiting for a31's tests\nChecking on a31 · 2m 10s", 260),
    ]

    func render(light: Bool) -> CGImage? {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let scale: CGFloat = 2, width: CGFloat = 529
        let scenes = Self.notices.map { notice, column in
            Fixture.withRenderScale(2) {
                RowBuilder.rows(HomeTurnStatusTests.state(typing: true, notice: notice), messages: [], now: HomeTurnStatusTests.t0,
                                width: column, scale: 2).filter { $0.key == "notice" || $0.key == "typing" }
            }
        }
        let height = scenes.reduce(CGFloat(16)) { total, rows in rows.reduce(total + 16) { $0 + $1.total } }
        guard let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        var y: CGFloat = 16
        for rows in scenes {
            for spec in rows {
                y += spec.gap
                let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
                if let image = Fixture.withRenderScale(2, { WideBitmap.make(size: size, scale: scale, opaque: false) { RowDraw.drawStatic(spec, $0, windowY: .nan) } }) {
                    let top = y - RowDraw.margin
                    ctx.draw(image, in: CGRect(x: 0, y: (height - top - size.height) * scale, width: size.width * scale, height: size.height * scale))
                }
                y += spec.height
            }
            y += 16
        }
        return ctx.makeImage()
    }

    @Test func theStatusLineDarkAndLight() throws {
        let dark = try #require(render(light: false))
        let light = try #require(render(light: true))
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
        let out = package.appendingPathComponent(".build/home-status-line.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
