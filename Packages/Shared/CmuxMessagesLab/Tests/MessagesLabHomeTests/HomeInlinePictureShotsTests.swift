import CmuxHomeCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The picture for the Chief's inline pictures (Lawrence, 2026-11-20): a Chief reply with a screenshot on its own line
/// (`![before, light](/abs/shot.png)`) and one inside a sentence, drawn by the real row renderer from rows the real
/// `RowBuilder` derived, and the quote above my reply to it. Light on the left, dark on the right, at 2x, into
/// `.build/home-inline-picture-shots.png` (a fleet step returns it with `--artifact`). It checks only that it drew;
/// `HomeInlinePictureTests` checks the parts. The same file draws the tree before the fix.
@MainActor @Suite(.serialized) struct HomeInlinePictureShotsTests {
    static let scale: CGFloat = 2, pad: CGFloat = 16, tileWidth: CGFloat = 520

    init() {
        HomeMarkdownPolicy.install()
        HomeTableRowProvider.reinstall()
    }

    /// A 2560 x 1600 "screenshot": a sidebar, a title bar and a window body, so the picture reads as one.
    static func screenshot(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2560, height: 1600))
        ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.36, blue: 0.86, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 1600))
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.62, blue: 0.18, alpha: 1))
        ctx.fill(CGRect(x: 760, y: 1080, width: 1640, height: 360))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.24, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 1500, width: 2560, height: 100))
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(out))
    }

    /// `rows` stacked by their gaps, as `RowDraw` draws them.
    private func stack(_ rows: [RowSpec], light: Bool) throws -> CGImage {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let height = rows.enumerated().reduce(CGFloat(0)) { $0 + $1.element.height + ($1.offset == 0 ? 0 : $1.element.gap) } + 2 * Self.pad
        let w = Int(Self.tileWidth * Self.scale), h = Int(height * Self.scale)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var top = Self.pad
        for (i, row) in rows.enumerated() {
            if i > 0 { top += row.gap }
            let size = CGSize(width: row.width, height: row.height + 2 * RowDraw.margin)
            let image = try #require(Fixture.withRenderScale(Self.scale) {
                WideBitmap.make(size: size, scale: Self.scale, opaque: false) { c in RowDraw.drawStatic(row, c, windowY: .nan) }
            })
            let y = height - top - row.height - RowDraw.margin
            ctx.draw(image, in: CGRect(x: 0, y: y * Self.scale, width: CGFloat(image.width), height: CGFloat(image.height)))
            top += row.height
        }
        return try #require(ctx.makeImage())
    }

    @Test func chiefPicturesLightAndDark() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inline-picture-\(UUID().uuidString)", isDirectory: true)
        let shot = folder.appendingPathComponent("before-light.png")
        try Self.screenshot(shot)
        let pictures = HomeTablePictures()
        _ = await pictures.prepare(shot.path)
        let text = "Before the fix:\n![before, light](\(shot.path))\nSee ![the shot](\(shot.path)) for the diff."
        let rows = ThreadQuoteMarkdownTests.rows(root: text, media: { pictures.asset($0) ?? pictures.loadingMark($0) }, width: Self.tileWidth)
        let root = rows.filter { $0.key.hasPrefix("part:k1:") }
        let quote = rows.filter { $0.key.hasPrefix("preview:") || $0.key.hasPrefix("part:k9:") }
        #expect(!root.isEmpty, "no root rows: \(rows.map(\.key))")
        var columns: [CGImage] = []
        for light in [true, false] {
            let top = try stack(root, light: light)
            let bottom = try stack(quote, light: light)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let ctx = try #require(CGContext(data: nil, width: top.width, height: top.height + bottom.height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(top, in: CGRect(x: 0, y: bottom.height, width: top.width, height: top.height))
            ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height))
            columns.append(try #require(ctx.makeImage()))
        }
        let gap = 24
        let totalW = columns.map(\.width).reduce(0, +) + gap, totalH = columns.map(\.height).max() ?? 0
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: totalW, height: totalH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))
        var x = 0
        for column in columns {
            ctx.draw(column, in: CGRect(x: x, y: totalH - column.height, width: column.width, height: column.height))
            x += column.width + gap
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/home-inline-picture-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
