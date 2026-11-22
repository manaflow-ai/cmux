import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
import WebKit

/// CLOSE GROUND FIX (review of #37344): a page pane that closes shows only its ground (`PaneContentAreaView.groundColor`,
/// read once at the close), and that ground must be the color the person saw in the page area:
/// - the error page or the sad tab when one covers the page (they paint `Palette.pageBackground` over it), not the
///   background of the document under them;
/// - the page's color now, read again when the appearance changes (a page that follows `prefers-color-scheme`);
/// - for a loaded page with no background of its own, the engine's canvas (white, dark under a dark color scheme), the
///   same rule as Chromium, never the window's color.
@MainActor @Suite(.serialized, .closesItsWindows) struct PageClosingGroundTests {
    typealias Pane = WebKitPagePaneMotionTests.Pane

    static let frame = NSRect(x: 0, y: 0, width: 600, height: 500)

    /// sRGB components of `color` (0-255), to compare colors made in different spaces.
    static func rgb(_ color: CGColor?) -> [CGFloat]? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent].map { ($0 * 255).rounded() }
    }

    static func load(_ html: String, in pane: Pane) async throws {
        let webView = pane.page.webView
        webView.loadHTMLString(html, baseURL: URL(string: "https://ground.example/"))
        try #require(await WebKitPagePaneMotionTests.poll { !webView.isLoading && webView.url?.host == "ground.example" },
                     "SETUP: the page did not load")
    }

    /// A loaded yellow page whose color the pane would close on, so only a status page's own color can pass.
    static func loadYellowPage(in pane: Pane) async throws {
        try await load("<html style=\"background: rgb(255, 255, 0)\"><body>page</body></html>", in: pane)
        try #require(await WebKitPagePaneMotionTests.poll { rgb(pane.area.groundColor) == [255, 255, 0, 255] },
                     "SETUP: the yellow page's color did not become the pane's ground")
    }

    /// A yellow page's link to a host that cannot be reached: the error page covers the page area in the theme's page
    /// color, and the closing pane shows that color, not the yellow of the document under it.
    @Test func aPaneShowingTheErrorPageClosesOnTheErrorPagesColor() async throws {
        let pane = Pane(frame: Self.frame)
        defer { pane.tearDown() }
        try await Self.loadYellowPage(in: pane) // the document under the error page
        let error = pane.chrome.pageStatus.errorView
        error.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, message: "not found",
                                    failingURL: URL(string: "https://unreachable.example/")))
        let shown = try #require(Self.rgb(error.layer?.backgroundColor), "SETUP: the error page paints no color")
        try #require(shown != [255, 255, 0, 255], "SETUP: the error page is the document's yellow")
        #expect(Self.rgb(pane.area.groundColor) == shown, "the closing ground is not the error page's color")
    }

    /// The page's process ended: the sad tab covers the page area, and the closing pane shows its color.
    @Test func aPaneShowingTheSadTabClosesOnTheSadTabsColor() async throws {
        let pane = Pane(frame: Self.frame)
        defer { pane.tearDown() }
        try await Self.loadYellowPage(in: pane)
        let gone = pane.chrome.pageStatus.goneView
        gone.show(BrowserProcessExit(reason: .crashed))
        let shown = try #require(Self.rgb(gone.layer?.backgroundColor), "SETUP: the sad tab paints no color")
        try #require(shown != [255, 255, 0, 255], "SETUP: the sad tab is the document's yellow")
        #expect(Self.rgb(pane.area.groundColor) == shown, "the closing ground is not the sad tab's color")
    }

    /// A loaded page with no background of its own is white (WebKit's canvas, as Chromium's): its pane closes on white,
    /// not on the chrome's window color.
    @Test func aLoadedPageWithNoBackgroundClosesOnWhite() async throws {
        let pane = Pane(frame: Self.frame)
        defer { pane.tearDown() }
        pane.window.appearance = NSAppearance(named: .aqua)
        try #require(Self.rgb(pane.chrome.layer?.backgroundColor) != [255, 255, 255, 255],
                     "SETUP: the chrome's own ground is white, so this test cannot tell the two apart")
        try await Self.load("<html><body>page</body></html>", in: pane)
        let white = await WebKitPagePaneMotionTests.poll { Self.rgb(pane.area.groundColor) == [255, 255, 255, 255] }
        #expect(white, "the closing ground is \(String(describing: Self.rgb(pane.area.groundColor))), not the page's white")
    }

    /// A page with `color-scheme: dark` and no background of its own, in a dark appearance: the engine paints a dark
    /// canvas, and the pane closes on a dark ground, not white and not the chrome's color.
    @Test func aDarkSchemePageWithNoBackgroundClosesDark() async throws {
        let pane = Pane(frame: Self.frame)
        defer { pane.tearDown() }
        pane.window.appearance = NSAppearance(named: .darkAqua)
        try await Self.load("<html style=\"color-scheme: dark\"><body>page</body></html>", in: pane)
        let chrome = Self.rgb(pane.chrome.layer?.backgroundColor)
        let dark = await WebKitPagePaneMotionTests.poll {
            guard let ground = Self.rgb(pane.area.groundColor), ground != chrome else { return false }
            return ground.prefix(3).allSatisfy { $0 < 64 }
        }
        #expect(dark, "the closing ground is \(String(describing: Self.rgb(pane.area.groundColor))) (chrome \(String(describing: chrome))), not the page's dark canvas")
    }

    /// A page that follows `prefers-color-scheme`, light at its load; the appearance turns dark: the pane closes on the
    /// page's dark color, read again at the appearance change, not the light one read at the load.
    @Test func anAppearanceChangeReadsThePagesColorAgain() async throws {
        let pane = Pane(frame: Self.frame)
        defer { pane.tearDown() }
        pane.window.appearance = NSAppearance(named: .aqua)
        try await Self.load("""
        <html><head><style>
        html { background: rgb(250, 250, 250) }
        @media (prefers-color-scheme: dark) { html { background: rgb(16, 48, 80) } }
        </style></head><body>page</body></html>
        """, in: pane)
        try #require(await WebKitPagePaneMotionTests.poll { pane.page.pageBackdropARGB == 0xFFFA_FAFA },
                     "SETUP: the light color read at the load did not apply")
        pane.window.appearance = NSAppearance(named: .darkAqua)
        let dark = await WebKitPagePaneMotionTests.poll { WebKitPagePaneMotionTests.isPageColor(pane.area.groundColor) }
        #expect(dark, "the closing ground is \(String(describing: Self.rgb(pane.area.groundColor))), not the page's dark rgb(16, 48, 80)")
    }
}
