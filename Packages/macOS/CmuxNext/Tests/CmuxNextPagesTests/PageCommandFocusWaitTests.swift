import AppKit
@testable import CmuxNextPages
import CmuxNextTestSupport
import Testing
import WebKit

/// Lawrence, 2026-11-15 ("the first Cmd+F press misses", about 1 in 20 fresh launches on cmux-lawrence-2): Cmd-F on a
/// Markdown page sends the page its find command, and the page focuses its find field later, in its own turn. Letters
/// typed in between went to the page before its field had focus and were lost. A wait that ended at the page's next
/// focus change did not help (5 misses in 60 launches): at launch the page's document focus moves on its own (its
/// window gets focus, the host gives it the keyboard), so the wait ended before the field had focus.
///
/// Now only the field's own focus ends the wait: the find field carries `data-cmux-command-focus="find"`, and the
/// page's readiness script reports focus on it (``PageInputReadiness/awaitFocus(on:)``). Until then the page is not
/// ready for typing, so the key router's type-ahead keeps the letters and types them into the field.
@MainActor
@Suite(.closesItsWindows)
struct PageCommandFocusWaitTests {
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

        /// A document with an editor and a find field, as the Markdown page has.
        func load() async {
            _ = await PageTestWait.value("load") { (done: @escaping (Bool) -> Void) in
                loaded = { done(true) }
                webView.loadHTMLString("<!doctype html><body><div id=editor contenteditable=true>text</div>"
                    + "<input id=find type=search data-cmux-command-focus=find></body>", baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?()
            loaded = nil
        }

        @discardableResult
        func run(_ script: String) async throws -> Any? {
            try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }
    }

    /// The editor taking focus first (the host gives the page the keyboard at launch) does not end the wait; the find
    /// field taking focus does, and the page reports ready for the letters kept meanwhile.
    @Test func onlyTheFindFieldsFocusEndsTheWait() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        try await page.run("document.getElementById('editor').focus();")
        #expect(page.readiness.isReady, "a page whose editor has focus is not ready: the test proves nothing")
        var ready = 0
        page.readiness.onReady = { ready += 1 }

        page.readiness.awaitFocus(on: "find")
        #expect(!page.readiness.isReady, "a page about to focus its find field counts as ready: the letters typed now are lost")
        try await page.run("document.getElementById('editor').blur(); document.getElementById('editor').focus();")
        #expect(!page.readiness.isReady, "another focus change ended the wait before the find field had focus")
        try await page.run("document.getElementById('find').focus();")
        #expect(page.readiness.isReady, "the find field took focus and the page is still not ready")
        #expect(ready == 1, "the type-ahead was not told the page is ready: \(ready)")
        #expect(page.readiness.commandFocus == "find")
    }

    /// A document that never had an editable focus (a fresh launch): the editor's first focus does not make it ready
    /// while the wait runs, so the letters go to the find field, not the editor.
    @Test func aNewDocumentsFirstFocusOnTheEditorDoesNotEndTheWait() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        #expect(!page.readiness.isReady)
        page.readiness.awaitFocus(on: "find")
        try await page.run("document.getElementById('editor').focus();")
        #expect(!page.readiness.isReady, "the editor's first focus made the page ready: the letters went to the editor")
        try await page.run("document.getElementById('find').focus();")
        #expect(page.readiness.isReady)
    }

    /// Cmd-F before the page's document loaded (60 fresh launches, 3 misses): the page runs the find command once it
    /// loads. The new document's first report ended the wait, its editor took focus first, and the page turned ready:
    /// the kept letters went to the editor, 40-210 ms before the find field had focus. A wait made before the document
    /// is for that document: its start keeps it, and its bound counts from the document's first focus.
    @Test func aWaitMadeBeforeTheDocumentLoadsHoldsUntilItsFindField() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        page.readiness.focusWaitLimit = .milliseconds(200)
        var ready = 0
        page.readiness.onReady = { ready += 1 }
        page.readiness.awaitFocus(on: "find")
        // The document comes later than the bound (the page window is still being made).
        try? await Task.sleep(for: .milliseconds(300))
        await page.load()
        try await page.run("document.getElementById('editor').focus();")
        #expect(!page.readiness.isReady, "the new document's start or its editor's focus ended the wait: the letters went to the editor")
        #expect(ready == 0, "the type-ahead was told the page is ready before its find field had focus: \(ready)")
        try await page.run("document.getElementById('find').focus();")
        #expect(page.readiness.isReady, "the find field took focus and the page is still not ready")
        #expect(ready == 1)
    }

    /// The find field already has focus (a second Cmd-F): nothing waits.
    @Test func aFieldThatAlreadyHasFocusHoldsNoKeys() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        try await page.run("document.getElementById('find').focus();")
        page.readiness.awaitFocus(on: "find")
        #expect(page.readiness.isReady, "a second Cmd-F held the keys although the find field had focus")
    }

    /// A focus that never comes (the page did not open its field) holds the keys only until the bound.
    @Test func aFocusThatNeverComesEndsAtItsBound() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        try await page.run("document.getElementById('editor').focus();")
        page.readiness.focusWaitLimit = .milliseconds(40)
        page.readiness.awaitFocus(on: "find")
        let deadline = ContinuousClock.now + .seconds(3)
        // test-only: polls for the bound's one-shot task, bounded by `deadline`
        while !page.readiness.isReady, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(page.readiness.isReady, "a focus that never came kept the page's keys")
    }
}
