import AppKit
import Foundation
import Testing
@testable import MessagesLabHome

/// The transcript's remaining caches are bounded or given to the host: Markdown's pictures are a
/// byte-capped LRU the host sizes and trims and no Markdown layout keeps their pixels, the text measurements keep a
/// few widths per part, are counted and trimmed by the host and keep their estimate bases, and the context menu
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

    private static func message(_ i: Int, text: String? = nil) -> MessagesLabHome.Message {
        MessagesLabHome.Message(id: "bounds\(i)", senderId: "p\(i % 3)", sentAt: "2026-10-27T12:00:00-07:00",
                                parts: [.text(text ?? "Message \(i) with a few words to measure", runs: [])],
                                replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    /// A text that wraps at every transcript width (so a narrower width cannot reuse its lines).
    private static let wrapping = Array(repeating: "a sentence long enough to wrap the bubble", count: 12).joined(separator: " ")

    /// The image sources a layout's boxes name.
    private static func imageSources(_ md: MarkdownLayout) -> [String] {
        md.boxes.compactMap { box in
            if case let .image(source, _) = box.kind { return source }
            return nil
        }
    }

    /// Hands out one picture for every source, and holds it only while the provider lives.
    private final class OnePicture: MarkdownImageProvider, Sendable {
        let picture: HomeShared<CGImage>
        init(_ picture: CGImage) { self.picture = HomeShared(picture) }
        func markdownImage(source: String, alt: String) -> CGImage? { picture.value }
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

    @Test func theTranscriptCachesCountAndTrimMarkdownPicturesAndMeasurements() throws {
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
        #expect(measurements.bytes > 0)
        #expect(caches.bytes == images.bytes + measurements.bytes, "the host does not see the measurements")
        #expect(caches.entryCount == 4 + 6)

        let measured = measurements.bytes
        caches.trim(toFraction: 0.5)
        #expect(images.count == 2, "a half trim kept \(images.count) of 4 equal pictures")
        #expect(measurements.count < 6 && measurements.bytes < measured, "a partial trim kept every text layout")
        #expect(measurements.partCount == 6, "a partial trim dropped an estimate basis")

        caches.trim(toFraction: 0)
        #expect(images.count == 0 && measurements.count == 0)
        #expect(caches.bytes == measurements.bytes, "a trim to 0 kept bytes other than the estimate bases")
        let remeasured = measurements.size(Self.message(0), 0, width: 320, scale: 2)
        #expect(remeasured.size.width > 0 && measurements.count == 1, "a measurement after the trim was not taken again")
    }

    /// A trim to 0 while Home shows keeps what the next rows pass estimates from: no exact Core Text measure on its turn.
    @Test func aTrimToZeroStillEstimatesThePartsMeasuredBefore() {
        let measurements = MeasureCache()
        let m = Self.message(7, text: Self.wrapping)
        let exact = measurements.size(m, 0, width: 600, scale: 2)
        #expect(!exact.estimated && measurements.count == 1)

        measurements.trim(toFraction: 0)
        #expect(measurements.count == 0 && measurements.partCount == 1)
        let misses = measurements.misses, estimates = measurements.estimates
        let estimated = measurements.size(m, 0, width: 200, estimate: true, scale: 2)
        #expect(estimated.estimated, "the part was not estimated after the trim")
        #expect(estimated.size.height > exact.size.height, "the estimate at a narrower width did not grow")
        #expect(measurements.misses == misses, "the estimate measured the part again")
        #expect(measurements.estimates == estimates + 1)
    }

    /// One message asked at many widths (a divider drag) keeps only its last few measurements.
    @Test func oneMessageAtManyWidthsKeepsAFewMeasurements() {
        let measurements = MeasureCache()
        let m = Self.message(8, text: Self.wrapping)
        let widths = (0..<64).map { 220 + CGFloat($0) * 7 }
        for width in widths { _ = measurements.size(m, 0, width: width, scale: 2) }
        #expect(measurements.count <= MeasureCache.widthsPerPart, "one part kept \(measurements.count) measurements")
        #expect(measurements.partCount == 1)
        let hits = measurements.hits
        _ = measurements.size(m, 0, width: widths[widths.count - 1], scale: 2)
        #expect(measurements.hits == hits + 1, "the latest width was not kept")
    }

    /// No Markdown layout keeps a picture's pixels: the block cache and the measurements hold its source, and drawing
    /// asks the provider, so a picture the provider drops is freed.
    @Test func aMarkdownLayoutKeepsNoPicture() throws {
        let previous = MarkdownImages.provider
        defer { MarkdownImages.provider = previous }
        let source = "file:///no-folder/\(UUID().uuidString).png"
        let text = "![a picture](\(source))"
        weak var pixels: NSData?
        let md: MarkdownLayout
        do {
            let data = NSData(data: Data(repeating: 0x80, count: 4 * 3 * 4))
            pixels = data
            let provider = try #require(CGDataProvider(data: data as CFData))
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let picture = try #require(CGImage(width: 4, height: 3, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: space,
                                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let pictures = OnePicture(picture)
            MarkdownImages.provider = pictures
            md = MarkdownLayoutEngine.layout(MarkdownStore.shared.document(text), source: text, maxWidth: 300)
            MarkdownImages.provider = previous
        }
        #expect(Self.imageSources(md) == [source], "the picture did not lay out as an image box")
        #expect(pixels == nil, "a Markdown layout kept the picture's pixels")
    }

    /// After a trim to 0, a layout at a second width and a draw of the first one decode the picture once, into the provider.
    @Test func aTrimmedPictureDecodesOnceForTheNextLayoutAndDraw() throws {
        let previous = MarkdownImages.provider
        defer { MarkdownImages.provider = previous }
        let folder = try Self.folder()
        let source = try Self.png("layout.png", in: folder)
        let images = HomeMarkdownImages(directory: folder)
        MarkdownImages.provider = images
        let text = "![a picture](\(source))"
        let doc = MarkdownStore.shared.document(text)
        let first = MarkdownLayoutEngine.layout(doc, source: text, maxWidth: 300)
        #expect(Self.imageSources(first) == [source])
        #expect(images.count == 1)

        images.trim(toFraction: 0)
        #expect(images.count == 0 && images.bytes == 0)
        let second = MarkdownLayoutEngine.layout(doc, source: text, maxWidth: 260)
        #expect(Self.imageSources(second) == [source])
        let kept = try #require(images.markdownImage(source: source, alt: "a picture"))
        #expect(images.count == 1 && images.bytes == Self.bytes(kept), "the second width made a second copy")

        // Drawing the first layout asks the provider: the one kept picture, no new decode.
        let ctx = try #require(CGContext(data: nil, width: 320, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        MarkdownDraw.draw(ctx, first, body: CGRect(origin: .zero, size: first.size), outgoing: false)
        #expect(images.count == 1 && images.markdownImage(source: source, alt: "a picture") === kept)

        // After another trim, the draw itself decodes the picture into the provider (the layout has none to draw).
        images.trim(toFraction: 0)
        MarkdownDraw.draw(ctx, first, body: CGRect(origin: .zero, size: first.size), outgoing: false)
        #expect(images.count == 1, "drawing did not ask the provider for the picture")
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
