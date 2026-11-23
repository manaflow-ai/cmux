import CmuxHomeCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The picture for Lawrence's 2026-11-20 report ("this preview thing is not very good"): the quote above my reply to
/// four Chief messages, each drawn by the real row renderer from rows the real `RowBuilder` derived: the before/after
/// table he quoted, a Markdown sentence with a link and code, two pictures alone, and a link card without a picture.
/// Light on the left, dark on the right, at 2x, into `.build/thread-quote-markdown-shots.png` (a fleet step returns it
/// with `--artifact`). It checks only that it drew; `ThreadQuoteMarkdownTests` checks the words and the thumbnail.
/// Self-contained apart from that suite's fixtures, so the same file draws the tree before the fix.
@MainActor @Suite(.serialized) struct ThreadQuoteMarkdownShotsTests {
    static let scale: CGFloat = 2, pad: CGFloat = 16, tileWidth: CGFloat = 520

    init() {
        HomeMarkdownPolicy.install()
        HomeTableRowProvider.reinstall()
    }

    /// The quote row and the reply under it, as `RowDraw` draws them, stacked by their gaps.
    private func tile(_ rows: [RowSpec], light: Bool) throws -> CGImage {
        let saved = Fixture.lightAppearance
        Fixture.lightAppearance = light
        defer { Fixture.lightAppearance = saved }
        let q = try #require(rows.firstIndex { $0.key.hasPrefix("preview:") })
        let shown = Array(rows[q...].prefix { row in
            if case .threadPreview = row.kind { return true }
            if case .part = row.kind { return true }
            return false
        }.prefix(2))
        let height = shown.reduce(CGFloat(0)) { $0 + $1.height + ($1.key == shown[0].key ? 0 : $1.gap) } + 2 * Self.pad
        let w = Int(Self.tileWidth * Self.scale), h = Int(height * Self.scale)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var top = Self.pad
        for (i, row) in shown.enumerated() {
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

    @Test func threadQuotesOfMarkdownLightAndDark() async throws {
        let (table, media) = try await ThreadQuoteMarkdownTests.beforeAfterTable()
        let roots: [(String, HomeMapping.Media)] = [
            (table, media),
            ("**Done.** See [PR 12](https://github.com/manaflow-ai/cmux/pull/12), run `bun test` and check _both_ themes.", { _ in nil }),
            ("![before](/tmp/none-a.png) ![after](/tmp/none-b.png)", { _ in nil }),
            ("https://github.com/manaflow-ai/cmux/pull/47431", { _ in nil }),
        ]
        var columns: [[CGImage]] = []
        for light in [true, false] {
            var tiles: [CGImage] = []
            for (text, media) in roots {
                tiles.append(try tile(ThreadQuoteMarkdownTests.rows(root: text, media: media, width: Self.tileWidth), light: light))
            }
            columns.append(tiles)
        }
        let gap = 24
        let colW = Int(Self.tileWidth * Self.scale)
        let totalW = colW * 2 + gap
        let totalH = columns[0].map(\.height).reduce(0, +)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: totalW, height: totalH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))
        for (c, tiles) in columns.enumerated() {
            var y = totalH
            for tile in tiles {
                y -= tile.height
                ctx.draw(tile, in: CGRect(x: c * (colW + gap), y: y, width: tile.width, height: tile.height))
            }
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/thread-quote-markdown-shots.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
