import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The user, 2026-11-05, on a Before|After table in the Chief chat: "ui for this needs to be better, like i want
/// to be able to expand and annotate. also should have better loading skeleton state". A click on a picture in a
/// table opens it large (arrow keys across the table's pictures, Before|After side by side); in the viewer it can
/// be marked up (arrows, boxes, pen, text) and sent back into the chat; while a picture loads its cell holds a
/// skeleton of the picture's own size, so nothing jumps when it arrives.
@Suite(.serialized) @MainActor struct HomePictureViewerTests {
    init() {
        HomeMarkdownPolicy.install()
        CustomRows.unregister(HomeTableRowProvider.kind)
        CustomRows.unregister(HomePlanRowProvider.kind)
        HomeTableRowProvider.install()
    }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("picture-viewer-\(UUID().uuidString)", isDirectory: true)
    }

    /// A PNG of `width` × `height` pixels filled with `gray` at `url`.
    static func png(at url: URL, width: Int, height: Int, gray: CGFloat = 0.4) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, try image(width: width, height: height, gray: gray), nil)
        #expect(CGImageDestinationFinalize(out))
    }

    static func image(width: Int, height: Int, gray: CGFloat = 1) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(ctx.makeImage())
    }

    /// The RGBA of `image` at (`x`, `y`), y down from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width), height: CGFloat(image.height)))
        return (data[0], data[1], data[2])
    }

    static func card(_ text: String, media: @escaping HomeMapping.Media) throws -> CustomPart {
        let parts = HomeMapping.parts(.text(text), media: media, markdown: true)
        return try #require(parts.compactMap { part -> CustomPart? in if case .custom(let c) = part { return c } else { return nil } }.first)
    }

    static func table(_ text: String, media: @escaping HomeMapping.Media) throws -> HomeTable {
        try #require(HomeTableRowProvider.payload(try card(text, media: media))).table
    }

    static func beforeAfter(_ f: URL) -> String {
        """
        | | Before | After |
        |---|---|---|
        | Light | ![before, light](\(f.appendingPathComponent("bl.png").path)) | ![after, light](\(f.appendingPathComponent("al.png").path)) |
        | Dark | ![before, dark](\(f.appendingPathComponent("bd.png").path)) | ![after, dark](\(f.appendingPathComponent("ad.png").path)) |
        """
    }

    static func shots(_ f: URL) throws {
        for name in ["bl", "al", "bd", "ad"] { try png(at: f.appendingPathComponent("\(name).png"), width: 2560, height: 1600) }
    }

    // MARK: Loading skeleton

    /// While a picture loads, its cell holds a skeleton of the picture's own aspect (no "[before]" text, no empty
    /// box), and the card is exactly as tall then as once the picture arrives: nothing jumps.
    @Test func aLoadingPictureHoldsASkeletonOfItsOwnSizeSoNothingJumps() async throws {
        let f = Self.folder()
        try Self.shots(f)
        let text = Self.beforeAfter(f)
        let pictures = HomeTablePictures()
        // Not asked for yet: every picture is loading (asking starts it, and its thumbnail can be quick).
        let early = HomeTableGrid(try Self.table(text, media: { pictures.loadingMark($0) }), available: 700)
        let slot = try #require(early.slots[1][1].first)
        #expect(slot.image == nil)
        #expect(slot.pixels == CGSize(width: 2560, height: 1600))
        #expect(early.cells[1][1].string.isEmpty)
        #expect(early.pictureRects(at: .zero).filter(\.loading).count == 4)
        for name in ["bl", "al", "bd", "ad"] { #expect(await pictures.prepare(f.appendingPathComponent("\(name).png").path) != nil) }
        let late = HomeTableGrid(try Self.table(text, media: { pictures.asset($0) ?? pictures.loadingMark($0) }), available: 700)
        #expect(late.slots[1][1].first?.image != nil)
        #expect(late.pictureRects(at: .zero).filter(\.loading).isEmpty)
        #expect(late.height == early.height)
        #expect(late.heights == early.heights)
        #expect(late.pictureRects(at: .zero).map(\.rect) == early.pictureRects(at: .zero).map(\.rect))
    }

    /// A picture that cannot load (no such file) shows its alt text, not a skeleton that never ends.
    @Test func aPictureThatCannotLoadShowsItsAltTextNotAnEndlessSkeleton() async throws {
        let f = Self.folder()
        let missing = f.appendingPathComponent("gone.png").path
        let pictures = HomeTablePictures()
        #expect(await pictures.prepare(missing) == nil)
        #expect(pictures.loadingMark(missing) == nil)
        let text = "| Shot | Note |\n|---|---|\n| ![gone](\(missing)) | moved |"
        let grid = HomeTableGrid(try Self.table(text, media: { pictures.asset($0) ?? pictures.loadingMark($0) }), available: 500)
        #expect(grid.slots[1][0].isEmpty)
        #expect(grid.cells[1][0].string == "[gone]")
    }

    // MARK: Expand

    /// A click on a picture finds that picture (not a menu of every link), and the viewer gets the table's
    /// pictures in reading order, each named by its row and column, with Before and After paired.
    @Test func aClickOnATablePictureOpensThatPictureWithTheTablesPicturesAround() async throws {
        let f = Self.folder()
        try Self.shots(f)
        let text = Self.beforeAfter(f)
        let pictures = HomeTablePictures()
        for name in ["bl", "al", "bd", "ad"] { _ = await pictures.prepare(f.appendingPathComponent("\(name).png").path) }
        let part = try Self.card(text, media: { pictures.asset($0) })
        let table = try #require(HomeTableRowProvider.payload(part)).table
        let grid = HomeTableGrid(table, available: 700)
        let rects = grid.pictureRects(at: .zero)
        #expect(rects.count == 4)
        let darkAfter = try #require(rects.first { $0.source.hasSuffix("ad.png") })
        let hit = HomeTableRowProvider.picture(part, at: CGPoint(x: darkAfter.rect.midX, y: darkAfter.rect.midY), width: 700)
        #expect(hit == darkAfter.source)
        #expect(HomeTableRowProvider.picture(part, at: CGPoint(x: 2, y: 2), width: 700) == nil)

        let gallery = try #require(HomePictureGallery(table: table, opening: darkAfter.source))
        #expect(gallery.items.count == 4)
        #expect(gallery.index == 3)
        #expect(gallery.items.map(\.title) == ["Light · Before", "Light · After", "Dark · Before", "Dark · After"])
        #expect(gallery.items[0].url == f.appendingPathComponent("bl.png"))
        #expect(gallery.partner(of: 3) == 2)
        #expect(gallery.partner(of: 0) == 1)
        #expect(gallery.moved(by: 1).index == 3)
        #expect(gallery.moved(by: -1).index == 2)
    }

    /// The viewer: the arrow keys step through the table's pictures, C shows Before and After side by side;
    /// one Esc closes the viewer, also from the comparison (the user, 2026-11-07: "i have to press esc twice").
    @Test func theViewerStepsComparesAndClosesFromTheKeyboard() async throws {
        let items = ["Light · Before", "Light · After", "Dark · Before", "Dark · After"].enumerated().map { i, title in
            HomePictureGallery.Item(source: "s\(i)", url: URL(fileURLWithPath: "/tmp/s\(i).png"), title: title, row: i / 2, column: i % 2)
        }
        let gallery = HomePictureGallery(items: items, index: 0)
        let picture = try Self.image(width: 400, height: 250)
        let viewer = HomePictureViewer(frame: CGRect(x: 0, y: 0, width: 900, height: 700), gallery: gallery, load: { _ in picture })
        var closed = 0
        viewer.onClose = { closed += 1 }
        await viewer.loaded()
        #expect(viewer.handle(.right))
        #expect(viewer.gallery.index == 1)
        #expect(viewer.handle(.left))
        #expect(viewer.gallery.index == 0)
        #expect(viewer.handle(.compare))
        #expect(viewer.isComparing)
        // One Esc closes, also from the comparison (the user, 2026-11-07: "i have to press esc twice").
        #expect(viewer.handle(.escape))
        #expect(closed == 1)
        await viewer.loaded()
    }

    // MARK: Annotate

    /// A box drawn on the picture is in the exported image at the picture's own pixels; undo takes it away.
    @Test func marksDrawIntoTheExportedPictureAndUndoTakesThemAway() throws {
        let picture = try Self.image(width: 200, height: 100)
        var markup = HomePictureMarkup()
        markup.add(.box(CGRect(x: 20, y: 20, width: 100, height: 50)))
        markup.add(.arrow(from: CGPoint(x: 150, y: 90), to: CGPoint(x: 180, y: 10)))
        markup.add(.pen([CGPoint(x: 5, y: 95), CGPoint(x: 40, y: 95)]))
        markup.add(.text(at: CGPoint(x: 130, y: 30), "fix"))
        let out = try #require(markup.render(onto: picture))
        #expect(out.width == 200 && out.height == 100)
        let edge = try Self.pixel(out, x: 20, y: 45)
        #expect(edge.r > 200 && edge.g < 120 && edge.b < 120)
        let inside = try Self.pixel(out, x: 70, y: 45)
        #expect(inside.r > 240 && inside.g > 240 && inside.b > 240)
        markup.undo()
        markup.undo()
        markup.undo()
        markup.undo()
        #expect(markup.marks.isEmpty)
        let plain = try #require(markup.render(onto: picture))
        #expect(try Self.pixel(plain, x: 20, y: 45).g > 240)
    }

    /// Reply sends the marked-up picture: a PNG at the original's size, with the marks, handed to the chat's
    /// attachment intake (the same path as a paste of a picture file).
    @Test func replySendsTheMarkedUpPictureAsAPNG() async throws {
        let picture = try Self.image(width: 300, height: 200)
        let gallery = HomePictureGallery(items: [.init(source: "s", url: URL(fileURLWithPath: "/tmp/s.png"), title: "Shot", row: 0, column: 0)], index: 0)
        let viewer = HomePictureViewer(frame: CGRect(x: 0, y: 0, width: 900, height: 700), gallery: gallery, load: { _ in picture },
                                       reply: HomePictureReply(directory: Self.folder()))
        await viewer.loaded()
        viewer.addMark(.box(CGRect(x: 10, y: 10, width: 100, height: 100)))
        var sent: URL?
        viewer.onReply = { sent = $0 }
        viewer.reply()
        viewer.close()
        await viewer.loaded()
        let url = try #require(sent)
        #expect(url.pathExtension == "png")
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(image.width == 300 && image.height == 200)
        #expect(try Self.pixel(image, x: 10, y: 50).r > 200)
        #expect(try Self.pixel(image, x: 10, y: 50).g < 120)
    }

    /// Whether this process reaches a pasteboard server: a fleet test step often does not, and there every
    /// write fails and every read returns nil (cmuxs-Mac-mini, fleet step 3 of u2891, 2026-11-05).
    nonisolated private static let hasPasteboard: Bool = {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-picture-reply-probe-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        return board.setString("probe", forType: .string) && board.string(forType: .string) == "probe"
    }()

    /// A shared private pasteboard carries the reply's file to the chat's intake (never the user's clipboard).
    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server"))
    func theReplyPasteboardIsPrivateAndCarriesTheFile() throws {
        let url = Self.folder().appendingPathComponent("annotated.png")
        try Self.png(at: url, width: 40, height: 30)
        let board = HomePictureReply.pasteboard(for: url)
        defer { board.releaseGlobally() }
        #expect(board.name != NSPasteboard.Name.general)
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map { $0.resolvingSymlinksInPath().path } == [url.resolvingSymlinksInPath().path])
    }
}
