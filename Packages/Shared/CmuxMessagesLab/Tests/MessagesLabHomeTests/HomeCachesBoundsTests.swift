import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// The transcript's remaining caches are bounded or given to the host (p07-memory-115): Markdown's pictures are a
/// byte-capped LRU the host sizes and trims, the text measurements go at a trim to 0 only, and the context menu
/// keeps glyphs for the tapbacks and the recent emoji alone.
@MainActor @Suite(.serialized) struct HomeCachesBoundsTests {
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-cache-bounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real 4 x 3 PNG named `name` in `folder`, as `file:` source text.
    private static func png(_ name: String, in folder: URL) throws -> String {
        let rep = try #require(NSBitmapImageRep.owned(pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let file = folder.appendingPathComponent(name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        return file.absoluteString
    }

    private static func bytes(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

    private static func message(_ i: Int) -> MessagesLabHome.Message {
        MessagesLabHome.Message(id: "bounds\(i)", senderId: "p\(i % 3)", sentAt: "2026-10-27T12:00:00-07:00",
                                parts: [.text("Message \(i) with a few words to measure", runs: [])],
                                replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    @Test func markdownPicturesStayUnderTheirBudgetDroppingTheOldestFirst() throws {
        let folder = try Self.folder()
        let sources = try (0..<3).map { try Self.png("pic\($0).png", in: folder) }
        let images = HomeMarkdownImages(directory: folder)
        #expect(images.budget == HomeMarkdownImages.defaultBudget)
        let first = try #require(images.markdownImage(source: sources[0], alt: ""))
        let each = Self.bytes(first)
        images.setBudget(bytes: 2 * each)

        _ = images.markdownImage(source: sources[1], alt: "")
        let newest = try #require(images.markdownImage(source: sources[2], alt: ""))
        #expect(images.bytes <= 2 * each, "the pictures kept \(images.bytes) bytes over a \(2 * each)-byte budget")
        #expect(images.markdownImage(source: sources[2], alt: "") === newest, "the newest picture was dropped")
        #expect(images.markdownImage(source: sources[0], alt: "") !== first, "the oldest picture was kept over the budget")
    }

    @Test func aTrimToZeroFreesEveryPictureAndTheNextAskDecodesItAgain() throws {
        let folder = try Self.folder()
        let source = try Self.png("again.png", in: folder)
        let images = HomeMarkdownImages(directory: folder)
        let first = try #require(images.markdownImage(source: source, alt: ""))
        #expect(images.count == 1 && images.bytes == Self.bytes(first))

        images.trim(toFraction: .nan)
        #expect(images.count == 1, "NaN freed a picture")
        images.trim(toFraction: 0)
        #expect(images.count == 0 && images.bytes == 0)

        let again = try #require(images.markdownImage(source: source, alt: ""))
        #expect(again !== first, "a trimmed picture was still kept")
        #expect(again.width == first.width && again.height == first.height)
    }

    @Test func aBudgetOfZeroKeepsNoPictureButStillShowsIt() throws {
        let folder = try Self.folder()
        let source = try Self.png("none.png", in: folder)
        let images = HomeMarkdownImages(directory: folder)
        images.setBudget(bytes: 0)
        #expect(images.markdownImage(source: source, alt: "") != nil)
        #expect(images.count == 0 && images.bytes == 0)
    }

    @Test func theTranscriptCachesSizeAndTrimMarkdownPicturesAndDropMeasurementsOnlyAtZero() throws {
        let folder = try Self.folder()
        let sources = try (0..<4).map { try Self.png("caches\($0).png", in: folder) }
        let images = HomeMarkdownImages(directory: folder)
        let measurements = MeasureCache()
        let caches = MessagesLabTranscriptCaches(rows: RowBitmaps(), media: MediaCache(), tiles: TileCache(), ownsSlices: false,
                                                 markdownImages: images, measurements: measurements)
        caches.setBudget(bytes: 21 << 20)
        #expect(images.budget == MessagesLabTranscriptCaches.shares(of: 21 << 20).markdown)

        for source in sources { _ = images.markdownImage(source: source, alt: "") }
        for i in 0..<6 { _ = measurements.size(Self.message(i), 0, width: 320, scale: 2) }
        try #require(measurements.count == 6)
        #expect(caches.bytes == images.bytes && caches.bytes > 0)
        #expect(caches.entryCount == 4)

        caches.trim(toFraction: 0.5)
        #expect(images.count == 2, "a half trim kept \(images.count) of 4 equal pictures")
        #expect(measurements.count == 6, "a partial trim dropped text measurements every layout reads")

        caches.trim(toFraction: 0)
        #expect(caches.bytes == 0 && images.count == 0)
        #expect(measurements.count == 0)
        let remeasured = measurements.size(Self.message(0), 0, width: 320, scale: 2)
        #expect(remeasured.size.width > 0 && measurements.count == 1, "a measurement after the trim was not taken again")
    }

    @Test func theMenuKeepsGlyphsOnlyForTapbacksAndRecentEmoji() {
        MenuGlyphs.removeAll()
        defer { MenuGlyphs.removeAll() }
        for kind in TapbackGlyph.all { _ = MenuGlyphs.image(.tapback(kind)) }
        // Far more distinct emoji than the limit, none of them recent.
        let scalars = (0x1F600..<0x1F600 + 3 * MenuGlyphs.glyphLimit).compactMap(Unicode.Scalar.init)
        for scalar in scalars { _ = MenuGlyphs.image(.emoji(String(Character(scalar)))) }
        #expect(MenuGlyphs.count <= MenuGlyphs.glyphLimit, "the menu kept \(MenuGlyphs.count) glyphs")
        // The tapbacks are never dropped: drawing one again is a hit.
        let love = MenuGlyphs.image(.tapback("love"))
        #expect(MenuGlyphs.image(.tapback("love")) === love)
        #expect(MenuGlyphs.count <= MenuGlyphs.glyphLimit)
    }
}
