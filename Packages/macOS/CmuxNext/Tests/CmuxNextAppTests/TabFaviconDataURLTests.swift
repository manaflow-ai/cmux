import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextTabs
import CoreGraphics
import Foundation
import Testing

/// A New Tab page is built on the key's turn of every Cmd-T and Cmd-N, and it lists every open
/// browser tab's icon and up to 40 recent pages' icons as inline images. Each was a PNG encode
/// per build (perf-lead issue 11); an icon is encoded once now, however many pages list it.
@MainActor
struct TabFaviconDataURLTests {
    private final class Encodes {
        var count = 0
    }

    private final class NoLoader: BrowserFaviconLoading {
        func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? { nil }
    }

    private static func icon(gray: CGFloat) throws -> TabImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return TabImage(try #require(context.makeImage()))
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

    @Test func noIconHasNoInlineImage() {
        let encodes = Encodes()
        #expect(Self.store(counting: encodes).dataURL(nil) == nil)
        #expect(encodes.count == 0)
    }
}
