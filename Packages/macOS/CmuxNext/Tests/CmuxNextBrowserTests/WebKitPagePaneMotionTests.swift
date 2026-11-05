import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
import WebKit

/// WebKit pages in pane motion (Lawrence 2026-11-05: "we need to try to resize webviews (both chrome and webkit) more
/// often so it is smoother"). In a key resize (Ctrl-Shift-H/J/K/L, a press or a held key) and in a divider drag, a WebKit
/// page takes its pane's page area in every motion frame: its `WKWebView` frame changes with the pane, never a held start
/// size cut by the pane, never past the pane's edge. While WebKit has not drawn the new size yet, the gap beside its last
/// frame shows the page's own background color (the view's background), not WebKit's default control color (m18/m20, as
/// #36520 for Chromium). Before this, a WebKit page's chrome could not follow a key hold (S3), so the pane's content area
/// held the whole chrome at its start size until the spring landed.
@MainActor @Suite(.serialized, .closesItsWindows) struct WebKitPagePaneMotionTests {
    struct Pane {
        let window: NSWindow
        let area: PaneContentAreaView
        let pane: BrowserPaneChrome
        let chrome: BrowserChromeView
        let page: WebKitTab

        init(frame: NSRect) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            area = PaneContentAreaView(frame: frame)
            page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            pane = BrowserPaneChrome()
            chrome = pane.bind(page, state: BrowserChromeTabState())
            chrome.frame = area.contentBounds
            chrome.autoresizingMask = [.width, .height]
            area.addSubview(chrome)
            window.contentView?.addSubview(area)
            window.orderFrontRegardless()
            area.layoutSubtreeIfNeeded()
        }

        /// What is wrong with the page in this frame: its view is not at the chrome's page area, the chrome does not
        /// cover the pane, or the page reaches past the pane's edge. Empty when the frame is right.
        func misses() -> [String] {
            var found: [String] = []
            let webView = page.webView
            if chrome.frame != area.bounds { found.append("chrome \(chrome.frame) is not the pane's area \(area.bounds)") }
            if webView.frame.size != chrome.contentContainer.bounds.size {
                found.append("page \(webView.frame.size) is not the page area \(chrome.contentContainer.bounds.size)")
            }
            let shown = webView.convert(webView.bounds, to: area)
            if !area.bounds.insetBy(dx: -0.5, dy: -0.5).contains(shown) {
                found.append("page \(shown) reaches past the pane \(area.bounds)")
            }
            return found
        }

        func tearDown() {
            area.hold = nil
            pane.drop()
            page.close()
            window.orderOut(nil)
            window.close()
        }
    }

    /// A key resize: the pane's leading edge moves right 120 pt and back past its start (a held key), as its spring
    /// frames do. In every frame the page is at the pane's page area, inside the pane.
    @Test func aKeyResizeShowsTheWebKitPageAtThePanesSizeInEveryFrame() throws {
        let pane = Pane(frame: NSRect(x: 200, y: 0, width: 600, height: 500))
        defer { pane.tearDown() }
        try #require(pane.misses().isEmpty, "SETUP: the page is not at its pane's size at rest: \(pane.misses())")

        pane.area.hold = PaneMotionHold(trailing: true, bottom: false)
        var misses: [String] = []
        let steps: [CGFloat] = (0...12).map { CGFloat($0) * 10 } + (0...12).map { CGFloat(12 - 2 * $0) * 10 }
        for (index, dx) in steps.enumerated() {
            pane.area.frame = NSRect(x: 200 + dx, y: 0, width: 600 - dx, height: 500)
            pane.area.layoutSubtreeIfNeeded()
            misses += pane.misses().map { "frame \(index): \($0)" }
        }
        #expect(misses.isEmpty, "\(misses.count) misses in \(steps.count) key-resize frames: \(misses.prefix(3))")

        pane.area.hold = nil
        pane.area.layoutSubtreeIfNeeded()
        #expect(pane.misses().isEmpty, "the page is not at its pane's size after the landing: \(pane.misses())")
    }

    /// A divider drag (no hold): the page lays out at each drag size.
    @Test func aDividerDragShowsTheWebKitPageAtThePanesSizeInEveryFrame() {
        let pane = Pane(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        defer { pane.tearDown() }
        var misses: [String] = []
        for width in stride(from: CGFloat(600), through: 360, by: -20) {
            pane.area.setFrameSize(NSSize(width: width, height: 500))
            pane.area.layoutSubtreeIfNeeded()
            misses += pane.misses().map { "width \(width): \($0)" }
        }
        #expect(misses.isEmpty, "\(misses.count) drag frames do not show the page at its pane's size: \(misses.prefix(3))")
    }

    /// A dark page in a key resize: the web view's own background, which shows where WebKit has not drawn the new size
    /// yet, is the page's background color, not WebKit's default (white, or the dark control color).
    @Test func theGapBesideAWebKitPageShowsThePagesColor() async throws {
        let pane = Pane(frame: NSRect(x: 200, y: 0, width: 600, height: 500))
        defer { pane.tearDown() }
        let webView = pane.page.webView
        webView.loadHTMLString("<html style=\"background: rgb(16, 48, 80)\"><body>page</body></html>",
                               baseURL: URL(string: "https://gap.example/"))
        try #require(await Self.poll { !webView.isLoading && webView.url?.host == "gap.example" },
                     "SETUP: the page did not load")

        pane.area.hold = PaneMotionHold(trailing: true, bottom: false)
        pane.area.frame = NSRect(x: 260, y: 0, width: 540, height: 500)
        pane.area.layoutSubtreeIfNeeded()
        let shown = await Self.poll {
            webView.displayIfNeeded()
            return Self.isPageColor(webView.layer?.backgroundColor)
        }
        #expect(shown, "the gap shows \(String(describing: webView.layer?.backgroundColor)), not the page's rgb(16, 48, 80)")
    }

    static func isPageColor(_ color: CGColor?) -> Bool {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let parts = color?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components, parts.count >= 3 else { return false }
        return zip(parts.prefix(3), [16.0, 48, 80]).allSatisfy { abs($0 * 255 - $1) <= 2 }
    }

    /// Polls `condition` every 20 ms for up to `seconds`, letting the run loop turn between checks.
    static func poll(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
