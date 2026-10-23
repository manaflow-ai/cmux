import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A hibernated tab wakes to its picture, not an empty page (perf-lead.md row 15: "wake shows a
/// picture in < 10 ms", both engines). A WebKit page restores in the same turn the tab is shown,
/// so its placeholder's picture never reached a frame: the pane showed the new, unpainted web
/// view (white, or the theme color) until the restored document drew. The woken page's chrome
/// now keeps the picture over the page until the page's first load ends, at most a moment after
/// the document commits, and never takes a click.
@MainActor @Suite(.serialized) struct WakePictureCoverTests {
    private static func picture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        return try #require(context.makeImage())
    }

    /// The chrome renders a state change on a later main-actor turn (`ObservationLoop`).
    private static func rendered() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private static func wokenPage() -> (MockBrowserTab, BrowserChromeView) {
        let engine = MockBrowserEngine(kind: .webkit, completesNavigationsImmediately: false)
        let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: page)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        chrome.layoutSubtreeIfNeeded()
        return (page, chrome)
    }

    @Test func aWokenPageShowsItsPictureUntilItsFirstLoadEnds() async throws {
        let (page, chrome) = Self.wokenPage()
        chrome.holdPicture(whileWaking: try Self.picture())
        let cover = try #require(chrome.wakePictureView, "the woken page showed no picture over its unpainted view")
        #expect(cover.superview === chrome.contentContainer)
        let subviews = chrome.contentContainer.subviews
        #expect((subviews.firstIndex(of: cover) ?? -1) > (subviews.firstIndex(of: page.contentView) ?? Int.max), "the picture is under the page")
        #expect(cover.hitTest(NSPoint(x: cover.bounds.midX, y: cover.bounds.midY)) == nil, "the picture takes the person's clicks")

        let navigation = page.makeNavigationID()
        page.simulate(.started(navigation, url: URL(string: "https://example.com/")))
        page.simulate(.committed(navigation, url: URL(string: "https://example.com/")))
        await Self.rendered()
        #expect(chrome.wakePictureView === cover, "the picture went before the committed document drew")

        page.simulate(.finished(navigation))
        await Self.rendered()
        #expect(chrome.wakePictureView == nil, "the picture stayed over the loaded page")
        #expect(cover.superview == nil)
    }

    /// A page that never loads (a dead content process) does not keep the picture over its error.
    @Test func aWokenPageWhoseProcessEndsDropsThePicture() async throws {
        let (page, chrome) = Self.wokenPage()
        chrome.holdPicture(whileWaking: try Self.picture())
        #expect(chrome.wakePictureView != nil)
        page.simulate(.processExited(BrowserProcessExit(reason: .crashed)))
        await Self.rendered()
        #expect(chrome.wakePictureView == nil)
    }

    /// No picture: nothing covers the page.
    @Test func noPictureNoCover() {
        let (_, chrome) = Self.wokenPage()
        chrome.holdPicture(whileWaking: nil)
        #expect(chrome.wakePictureView == nil)
    }
}
