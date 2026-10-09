import AppKit
import CmuxNextBrowser
import CmuxNextTabs
import Observation
import Testing
@testable import CmuxNextApp

/// Browser tabs show their page's favicon, a throbber while the
/// page loads, and a globe until a favicon exists (nxdog13: "browser tabs
/// need to support favicons").
@Suite struct BrowserTabIconStateTests {
    static let icon = TabImage(NSImage(size: NSSize(width: 4, height: 4)).cgImage(forProposedRect: nil, context: nil, hints: nil)
        ?? CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!)

    @Test func loadingShowsTheThrobberInPlaceOfTheFavicon() {
        #expect(BrowserTabIconState.resolve(isLoading: true, isDormant: false, favicon: Self.icon) == .throbber)
        #expect(BrowserTabIconState.resolve(isLoading: true, isDormant: false, favicon: nil) == .throbber)
    }

    @Test func aLoadedPageShowsItsFaviconElseAGlobe() {
        #expect(BrowserTabIconState.resolve(isLoading: false, isDormant: false, favicon: Self.icon) == .favicon(Self.icon))
        #expect(BrowserTabIconState.resolve(isLoading: false, isDormant: false, favicon: nil) == .globe)
    }

    /// `appearance.statusIndicator.showPageLoading` off: the favicon stays.
    @Test func pageLoadingOffKeepsTheFavicon() {
        #expect(BrowserTabIconState.resolve(isLoading: true, isDormant: false, favicon: Self.icon, showsLoading: false) == .favicon(Self.icon))
        #expect(BrowserTabIconState.resolve(isLoading: true, isDormant: false, favicon: nil, showsLoading: false) == .globe)
    }

    @Test func aHibernatedTabNeverShowsTheThrobber() {
        #expect(BrowserTabIconState.resolve(isLoading: true, isDormant: true, favicon: Self.icon) == .favicon(Self.icon))
    }

    @Test func applyingSetsTheStripItem() {
        var item = TabItem(id: TabID("b"), title: "b", icon: .symbol("globe"))
        BrowserTabIconState.favicon(Self.icon).apply(to: &item)
        #expect(item.icon == .image(Self.icon))
        BrowserTabIconState.throbber.apply(to: &item)
        #expect(item.isBusy)
    }
}

