import AppKit
import CmuxNextPages
import CmuxNextTestSupport
import Testing
import WebKit

/// Text typed ahead goes into the field it was typed for, also when that field got focus again while
/// the text was on its way (cmux-lawrence-2, 2026-11-12: + button, then "hello" typed at once, left
/// "lo"). A New Tab page's field is focused before its window has focus; when the window gets focus,
/// the field fires `focusin` again. That raised the page's focus epoch past the one the app read when
/// it took the text, and the page refused the insert as if focus had moved, so the text was lost.
@MainActor
@Suite(.closesItsWindows)
struct PageInputRefocusTests {
    final class Page: NSObject, WKNavigationDelegate {
        let readiness: PageInputReadiness
        let webView: WKWebView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private var loaded: (() -> Void)?

        override init() {
            let configuration = WKWebViewConfiguration()
            readiness = PageInputReadiness(configuration: configuration)
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), configuration: configuration)
            super.init()
            readiness.attach(webView)
            window.contentView = webView
            webView.navigationDelegate = self
        }

        func load() async {
            _ = await PageTestWait.value("load") { (done: @escaping (Bool) -> Void) in
                loaded = { done(true) }
                webView.loadHTMLString("<!doctype html><body><input id=a><input id=b></body>", baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?()
            loaded = nil
        }

        /// Runs `script` in the page; the messages it posts arrive before its reply.
        @discardableResult
        func run(_ script: String) async throws -> Any? {
            try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }

        func value(_ id: String) async throws -> String? {
            try await run("return document.getElementById('\(id)').value;") as? String
        }
    }

    /// The field typed for blurred and got focus again (its window got focus) after the app took the
    /// text: the text lands in it.
    @Test func theSameFieldFocusedAgainTakesTheText() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        try await page.run("document.getElementById('a').focus();")
        let taken = page.readiness.focusEpoch
        #expect(taken > 0, "the page saw no focus")
        try await page.run("const a = document.getElementById('a'); a.blur(); a.focus();")
        #expect(await page.readiness.insert("hello", expectedEpoch: taken))
        #expect(try await page.value("a") == "hello")
    }

    /// Focus moved to another field after the app took the text: the page refuses it there.
    @Test func anotherFieldRefusesTheText() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        try await page.run("document.getElementById('a').focus();")
        let taken = page.readiness.focusEpoch
        try await page.run("document.getElementById('b').focus();")
        #expect(await page.readiness.insert("hello", expectedEpoch: taken) == false)
        #expect(try await page.value("b") == "")
    }

    /// Focus went to another field and came back: the text was typed while it was elsewhere, so the
    /// page still refuses it.
    @Test func aFieldLeftForAnotherRefusesTheText() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        try await page.run("document.getElementById('a').focus();")
        let taken = page.readiness.focusEpoch
        try await page.run("document.getElementById('b').focus(); document.getElementById('a').focus();")
        #expect(await page.readiness.insert("hello", expectedEpoch: taken) == false)
        #expect(try await page.value("a") == "")
    }
}
