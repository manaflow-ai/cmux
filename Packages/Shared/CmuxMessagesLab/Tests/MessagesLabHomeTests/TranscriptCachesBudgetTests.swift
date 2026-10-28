import AppKit
import Testing
@testable import MessagesLabHome

/// The transcript's pixel caches take their size from the host and give bytes back on request:
/// `setBudget(bytes:)` caps each cache, `trim(toFraction:)` frees the least recently used first, a budget of 0
/// keeps nothing, and a row drawn again after a trim has the same pixels.
@MainActor @Suite(.serialized) struct TranscriptCachesBudgetTests {
    /// A date separator row: drawn text, so its bitmap has pixels to compare.
    private static func separator(_ n: Int) -> RowSpec {
        RowSpec(key: "sep:budget-\(n)", kind: .separator(bold: "Today", rest: "9:\(10 + n) AM"), gap: 8, height: 14)
    }

    private static func image(side: CGFloat = 16) throws -> CGImage {
        try #require(WideBitmap.make(size: CGSize(width: side, height: side), scale: 2, opaque: false) { ctx in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        })
    }

    private static func bytes(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    /// The bitmap's pixel bytes, for an equal-pixels check.
    private static func pixels(_ image: CGImage) -> Data? {
        image.dataProvider?.data.map { $0 as Data }
    }

    private static func tile(_ lineage: Int) -> TileCache.Key {
        TileCache.Key(lineage: lineage, start: 0, end: 10, final: true, column: 300, chunk: 0, outgoing: false, scale: 2, palette: 0)
    }

    @Test func rowBitmapsTrimToAFractionAndToNothing() throws {
        let cache = RowBitmaps()
        let rows = try (0..<8).map { n in (Self.separator(n), try Self.image()) }
        cache.insert(rows, scale: 2)
        let full = cache.bytes
        try #require(full == rows.count * Self.bytes(rows[0].1))

        cache.trim(toFraction: 0.5)
        #expect(cache.bytes <= full / 2)
        #expect(cache.bytes > 0, "a half trim emptied the cache")
        #expect(cache.image(for: rows[0].0, scale: 2) == nil, "the oldest row kept its bitmap")
        #expect(cache.image(for: rows[7].0, scale: 2) != nil, "the newest row lost its bitmap")

        cache.trim(toFraction: 0)
        #expect(cache.bytes == 0)
        #expect(cache.count == 0)
    }

    @Test func aRowDrawnAgainAfterATrimHasTheSamePixels() throws {
        let cache = RowBitmaps()
        let spec = Self.separator(42)
        let first = try #require(RowBitmaps.render(spec, scale: 2))
        cache.insert([(spec, first)], scale: 2)
        cache.trim(toFraction: 0)
        #expect(cache.image(for: spec, scale: 2) == nil)

        let again = try #require(RowBitmaps.render(spec, scale: 2))
        cache.insert([(spec, again)], scale: 2)
        let kept = try #require(cache.image(for: spec, scale: 2))
        #expect(kept.width == first.width && kept.height == first.height)
        #expect(Self.pixels(kept) == Self.pixels(first), "the row drawn after the trim differs")
    }

    @Test func aBudgetOfZeroKeepsNoBitmapImageOrTile() throws {
        let image = try Self.image()
        let rows = RowBitmaps(), media = MediaCache(), tiles = TileCache()
        let caches = MessagesLabTranscriptCaches(rows: rows, media: media, tiles: tiles, ownsSlices: false)
        caches.setBudget(bytes: 0)

        rows.insert([(Self.separator(1), image)], scale: 2)
        media.store("photo.png@2.0", UIImage(cgImage: image, scale: 2))
        tiles.put(Self.tile(1), image)
        #expect(rows.bytes == 0)
        #expect(media.bytes == 0)
        #expect(tiles.bytes == 0)
        #expect(caches.bytes == 0)
        #expect(caches.entryCount == 0)
    }

    @Test func theCachesTrimTogetherAndTheBudgetSplitsAsMessagesLabSizedThem() throws {
        let image = try Self.image()
        let each = Self.bytes(image)
        let rows = RowBitmaps(), media = MediaCache(), tiles = TileCache()
        let caches = MessagesLabTranscriptCaches(rows: rows, media: media, tiles: tiles, ownsSlices: false)
        for n in 0..<6 {
            rows.insert([(Self.separator(n), image)], scale: 2)
            media.store("photo\(n).png@2.0", UIImage(cgImage: image, scale: 2))
            tiles.put(Self.tile(n), image)
        }
        try #require(caches.bytes == 18 * each)

        caches.trim(toFraction: 0.5)
        #expect(caches.bytes <= 9 * each)
        caches.trim(toFraction: .nan)
        #expect(caches.bytes > 0, "NaN freed bitmaps")
        caches.trim(toFraction: 0)
        #expect(caches.bytes == 0)

        let share = MessagesLabTranscriptCaches.shares(of: 336 << 20)
        #expect(share.rows + share.media + share.tiles + share.markdown == 336 << 20)
        #expect(share.rows > share.media && share.media > share.tiles && share.tiles > share.markdown)
        caches.setBudget(bytes: 336 << 20)
        #expect(rows.byteBudget == share.rows)
        #expect(tiles.budget == share.tiles)
        #expect(media.budget == MediaCache.labBudget ?? share.media)
    }

    /// The line cache is outside the host's consumer (it lives only while its reply streams): its fixed byte
    /// cap is its bound, and a line over the cap is rendered but not kept.
    @Test func theMarkdownLineCacheCountsItsBytesAndStaysUnderItsCap() {
        let lines = HomeMarkdownLineCache(chips: false)
        #expect(lines.budget == HomeMarkdownLineCache.defaultBudget)
        for n in 0..<20 { _ = lines.rendered("line \(n) with **bold** words"[...]) }
        #expect(lines.count == 20)
        #expect(lines.bytes > 0)

        let small = HomeMarkdownLineCache(budget: 64, chips: false)
        for n in 0..<20 { _ = small.rendered("line \(n) with **bold** words"[...]) }
        #expect(small.bytes <= 64, "the line cache kept \(small.bytes) bytes over its 64-byte budget")
        let long = String(repeating: "word ", count: 40)
        #expect(small.rendered(long[...]).text == lines.rendered(long[...]).text, "a line over the cap rendered differently")
        #expect(small.bytes == 0 && small.count == 0, "a line over the cap was kept")
    }

    @Test func aTrimTargetNeverFreesMoreThanAskedOrTraps() {
        #expect(1_000.trimTarget(0.25) == 250)
        #expect(1_000.trimTarget(-1) == 0)
        #expect(1_000.trimTarget(2) == 1_000)
        #expect(1_000.trimTarget(.nan) == 1_000)
        #expect(1_000.trimTarget(.infinity) == 1_000)
        #expect((-5).trimTarget(0.5) == 0)
    }
}
