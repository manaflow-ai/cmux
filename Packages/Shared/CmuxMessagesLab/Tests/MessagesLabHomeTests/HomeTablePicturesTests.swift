import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Before and after shots an agent's table names by path or web address (the user, 2026-11-04, msg 21749:
/// "we need to improve before/after thing"; the cells showed "[before] [after]"): each draws as a thumbnail
/// in its cell, GitHub PR style, and a click opens the original.
@Suite(.serialized) struct HomeTablePicturesTests {
    init() {
        HomeMarkdownPolicy.install()
        HomeTableRowProvider.isOn = true
        CustomRows.unregister(HomeTableRowProvider.kind)
        CustomRows.unregister(HomePlanRowProvider.kind)
        HomeTableRowProvider.install()
    }

    /// A gray PNG of `width` × `height` pixels at `url`.
    static func png(at url: URL, width: Int, height: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(out))
    }

    /// A folder outside Home's media folder (where an agent writes its shots).
    static func shotsFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("table-shots-\(UUID().uuidString)", isDirectory: true)
    }

    static func grid(_ text: String, media: @escaping HomeMapping.Media) throws -> HomeTableGrid {
        let parts = HomeMapping.parts(.text(text), media: media, markdown: true)
        let card = try #require(parts.compactMap { part -> CustomPart? in if case .custom(let c) = part { return c } else { return nil } }.first)
        return HomeTableGrid(try #require(HomeTableRowProvider.payload(card)).table, available: 700)
    }

    @Test func localPathPicturesDrawAsThumbnailsInTheirCells() async throws {
        let folder = Self.shotsFolder()
        let before = folder.appendingPathComponent("before.png"), after = folder.appendingPathComponent("after.png")
        try Self.png(at: before, width: 2560, height: 1600)
        try Self.png(at: after, width: 2560, height: 1600)
        let text = """
        | Before | After |
        |---|---|
        | ![before](\(before.path)) | ![after](\(after.absoluteString)) |
        """
        let pictures = HomeTablePictures()
        // Not made yet: the alt text shows, and asking starts the thumbnail.
        let early = try Self.grid(text, media: { pictures.asset($0) })
        #expect(early.pictures[1][0].isEmpty)
        #expect(early.cells[1][0].string == "[before]")
        let thumbnail = try #require(await pictures.prepare(before.path))
        #expect(await pictures.prepare(after.absoluteString) != nil)
        // The thumbnail is small (never the 2560 px original) and in Home's media folder, the one it draws from.
        #expect(URL(fileURLWithPath: thumbnail).deletingLastPathComponent().resolvingSymlinksInPath().path
            == HomeMedia.directory.resolvingSymlinksInPath().path)
        let grid = try Self.grid(text, media: { pictures.asset($0) })
        let shot = try #require(grid.pictures[1][0].first)
        #expect(max(shot.width, shot.height) <= HomeTablePictures.maxPixel)
        #expect(grid.pictures[1][1].count == 1)
        #expect(grid.cells[1][0].string.isEmpty && grid.cells[1][1].string.isEmpty)
        // Side by side, each as tall as the row lets it, the row as tall as the thumbnails.
        #expect(grid.heights[1] >= HomeTableGrid.pictureSize(shot, width: grid.widths[0] - 2 * HomeTableGrid.cellPadX).height)
        // A click opens the original, not the thumbnail.
        #expect(HomeTablePictures.original(before.path) == before)
        #expect(HomeTablePictures.original(after.absoluteString) == after)
    }

    @Test func webPicturesAreFetchedOnceAndDrawInTheirCells() async throws {
        let folder = Self.shotsFolder()
        let served = folder.appendingPathComponent("served.png")
        try Self.png(at: served, width: 800, height: 500)
        let fetched = Fetches()
        let pictures = HomeTablePictures(fetch: { url in
            await fetched.add(url)
            let copy = folder.appendingPathComponent(UUID().uuidString + ".png")
            try FileManager.default.copyItem(at: served, to: copy)
            return copy
        })
        let source = "https://example.com/shots/after.png"
        let text = """
        | Before | After |
        |---|---|
        | ![before](https://example.com/shots/before.png) | ![after](\(source)) |
        """
        #expect(await pictures.prepare(source) != nil)
        let grid = try Self.grid(text, media: { $0 == source ? pictures.asset($0) : nil })
        #expect(grid.pictures[1][1].count == 1)
        #expect(grid.cells[1][0].string == "[before]")
        #expect(await fetched.urls == [URL(string: source)])
        #expect(HomeTablePictures.original(source) == URL(string: source))
    }

    @Test func onlyPictureFilesAndHttpsDraw() async throws {
        let folder = Self.shotsFolder()
        let notes = folder.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a picture".utf8).write(to: notes)
        let pictures = HomeTablePictures(fetch: { _ in throw URLError(.cancelled) })
        #expect(await pictures.prepare(notes.path) == nil)
        #expect(await pictures.prepare(folder.appendingPathComponent("missing.png").path) == nil)
        #expect(!HomeTablePictures.handles("http://example.com/a.png"))
        #expect(pictures.asset("http://example.com/a.png") == nil)
        #expect(await pictures.prepare("https://example.com/a.png") == nil)
    }
}

/// The URLs a fake fetch was asked for.
private actor Fetches {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}
