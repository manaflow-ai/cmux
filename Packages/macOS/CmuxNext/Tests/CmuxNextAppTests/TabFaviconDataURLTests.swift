import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextTabs
import CoreGraphics
import Foundation
import Testing

/// A New Tab page is built on the key's turn of every Cmd-T and Cmd-N, and it lists every open
/// browser tab's icon and up to 40 recent pages' icons as inline images. Each was a PNG encode
/// per build (perf-lead issue 11); an icon is encoded once now, however many pages list it, and
/// at the size the page draws it.
@MainActor
struct TabFaviconDataURLTests {
    private final class Encodes {
        var count = 0
    }

    private final class NoLoader: BrowserFaviconLoading {
        func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? { nil }
    }

    private static func icon(gray: CGFloat, width: Int = 4, height: Int = 4) throws -> TabImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return TabImage(try #require(context.makeImage()))
    }

    /// The pixel size of the image a data URL holds.
    private static func pixels(_ dataURL: String) throws -> (width: Int, height: Int) {
        let base64 = try #require(dataURL.split(separator: ",", maxSplits: 1).last.map(String.init))
        let data = try #require(Data(base64Encoded: base64))
        let rep = try #require(NSBitmapImageRep(data: data))
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    private static func store(counting encodes: Encodes) -> TabFaviconStore {
        TabFaviconStore(loader: NoLoader(), encode: { image in
            encodes.count += 1
            return TabFaviconStore.png(image)
        })
    }

    @Test func anIconIsEncodedOnceHoweverManyPagesListIt() throws {
        let encodes = Encodes()
        let store = Self.store(counting: encodes)
        let icon = try Self.icon(gray: 0.25)
        let first = try #require(store.dataURL(icon))
        for _ in 0..<40 { #expect(store.dataURL(icon) == first) }
        #expect(first.hasPrefix("data:image/png;base64,"))
        #expect(encodes.count == 1)
    }

    @Test func eachIconHasItsOwnImage() throws {
        let encodes = Encodes()
        let store = Self.store(counting: encodes)
        let dark = try Self.icon(gray: 0.1), light = try Self.icon(gray: 0.9)
        let darkURL = try #require(store.dataURL(dark)), lightURL = try #require(store.dataURL(light))
        #expect(darkURL != lightURL)
        #expect(store.dataURL(dark) == darkURL)
        #expect(encodes.count == 2)
    }

    /// The page's icon box (`.nt-row-glyph`, 16 px) at 2x.
    private static let drawnPixels = 32

    /// A site's icon arrives at whatever size the site serves (a 180 px touch icon, a 256 px
    /// `favicon.ico` layer; the loader allows 1 MiB). The page draws it in a 16 pt box, so it is
    /// inlined at 32 px at most (2x), keeping its shape: every Cmd-T and Cmd-N encodes and sends
    /// each listed icon into the page on the key's turn, and a full-size icon is 10 to 100 times
    /// the bytes of the one drawn.
    @Test(arguments: [(256, 256), (180, 180), (512, 128), (64, 32)])
    func aLargeIconIsInlinedAtTheSizeThePageDrawsIt(width: Int, height: Int) throws {
        let store = Self.store(counting: Encodes())
        let url = try #require(store.dataURL(try Self.icon(gray: 0.5, width: width, height: height)))
        let inlined = try Self.pixels(url)
        #expect(max(inlined.width, inlined.height) == Self.drawnPixels, "\(width)x\(height) inlined at \(inlined)")
        // The same shape: the long side at the limit, the short one in proportion (rounded).
        #expect(abs(inlined.width * height - inlined.height * width) <= max(width, height), "\(width)x\(height) inlined at \(inlined)")
    }

    /// An icon at or under the drawn size goes as it is (never scaled up).
    @Test(arguments: [(16, 16), (32, 32), (24, 12)])
    func aSmallIconIsInlinedAsItIs(width: Int, height: Int) throws {
        let store = Self.store(counting: Encodes())
        let url = try #require(store.dataURL(try Self.icon(gray: 0.5, width: width, height: height)))
        let inlined = try Self.pixels(url)
        #expect(inlined.width == width && inlined.height == height)
    }

    /// The cache holds 256 icons, least recently used out: an icon every page lists (the open
    /// tabs') is read on every build and stays, however many other icons pass through (a STRESS
    /// session's tabs plus 40 history icons plus closed items).
    @Test func anIconInUseStaysEncodedWhileOthersPassThrough() throws {
        let encodes = Encodes()
        let store = Self.store(counting: encodes)
        let used = try Self.icon(gray: 0.3)
        _ = store.dataURL(used)
        var others: [TabImage] = []
        for index in 0..<600 {
            let other = try Self.icon(gray: CGFloat(index % 100) / 100)
            others.append(other)
            _ = store.dataURL(other)
            _ = store.dataURL(used)
        }
        #expect(encodes.count == 1 + others.count, "the icon in use was encoded again \(encodes.count - 1 - others.count) times")
    }

    /// The cache keeps an icon's inline image, not the icon: a full-size icon the strip's image
    /// cache dropped is freed.
    @Test func theCacheDoesNotKeepAnIconAlive() throws {
        let store = Self.store(counting: Encodes())
        weak var gone: TabImage?
        try {
            let icon = try Self.icon(gray: 0.7, width: 256, height: 256)
            gone = icon
            _ = store.dataURL(icon)
        }()
        #expect(gone == nil)
    }

    @Test func noIconHasNoInlineImage() {
        let encodes = Encodes()
        #expect(Self.store(counting: encodes).dataURL(nil) == nil)
        #expect(encodes.count == 0)
    }
}
