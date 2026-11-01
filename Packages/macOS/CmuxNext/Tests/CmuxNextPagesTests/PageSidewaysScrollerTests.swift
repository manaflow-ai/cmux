import AppKit
import CmuxNextPages
import CmuxNextTestSupport
import Testing
import WebKit

/// A page reports when the pointer is over a box that scrolls sideways itself, so the layout leaves
/// a horizontal swipe there to the page (MARKDOWN-TABLE-SCROLL, user 2026-10-20). The document holds
/// the five cases of the user's markdown-table-scroll-test.md, drawn as the markdown viewer draws
/// them (each table in an `overflow: auto hidden` wrapper as wide as the column): a 20-column
/// table, one long unbroken cell, code in cells, a 40-row table and a small table.
@MainActor
@Suite(.closesItsWindows)
struct PageSidewaysScrollerTests {
    private static let html: String = {
        let row = { (cells: [String]) in "<tr>" + cells.map { "<td>\($0)</td>" }.joined() + "</tr>" }
        let wide = (1...20).map { "Column \($0) heading" }
        let tall = (1...40).map { row(["\($0)", "alpha", "bravo", "charlie", "delta"]) }.joined()
        let long = "ThisIsOneVeryLongUnbrokenTokenWithNoSpacesThatShouldForceHorizontalScrolling_0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let code = "<code>cmux tab create browser --pane pane_0f51b2b2017235ef8af3822f4fd6093b --url http://127.0.0.1:8766/index.html</code>"
        return """
        <!doctype html><html><head><style>
          body { margin: 0; font: 14px sans-serif; }
          .column { width: 300px; margin: 0 20px; }
          code { font-family: monospace; }
          .tableWrapper { max-width: 100%; overflow: auto hidden; overscroll-behavior-x: contain; margin-bottom: 8px; }
          table { border-collapse: separate; border-spacing: 0; white-space: normal; }
          td { padding: 2px 6px; }
        </style></head><body><div class="column">
          <p id="text">Plain text in the column.</p>
          <div class="tableWrapper"><table id="wide">\(row(wide))\(row(wide))</table></div>
          <div class="tableWrapper"><table id="long">\(row(["long", long]))</table></div>
          <div class="tableWrapper"><table id="code">\(row(["tab", code, "<code>tab_a85e</code>"]))</table></div>
          <div class="tableWrapper"><table id="tall">\(tall)</table></div>
          <div class="tableWrapper"><table id="small">\(row(["Left", "Center", "Right"]))</table></div>
          <div id="shadowWide"></div>
          <div id="shadowFits"></div>
        </div><script>
          // A code card as @pierre/diffs draws one: its sideways scroller is inside the host's shadow root.
          for (const [id, text] of [['shadowWide', '\(long)\(long)'], ['shadowFits', 'short line']]) {
            const root = document.getElementById(id).attachShadow({ mode: 'open' });
            root.innerHTML = '<pre style="margin:0;overflow:scroll clip;white-space:pre"><code>' + text + '</code></pre>';
          }
        </script></body></html>
        """
    }()

    final class Page: NSObject, WKNavigationDelegate {
        let readiness: PageInputReadiness
        let webView: WKWebView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 1400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        private var loaded: (() -> Void)?

        override init() {
            let configuration = WKWebViewConfiguration()
            readiness = PageInputReadiness(configuration: configuration)
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 440, height: 1400), configuration: configuration)
            super.init()
            window.contentView = webView
            webView.navigationDelegate = self
        }

        func load() async {
            _ = await PageTestWait.value("load") { (done: @escaping (Bool) -> Void) in
                loaded = { done(true) }
                webView.loadHTMLString(PageSidewaysScrollerTests.html, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?()
            loaded = nil
        }

        /// Moves the pointer to the middle of `#id` (or off the page with nil) and returns the
        /// page's report. Messages the event posts arrive before the script's reply.
        func pointer(over id: String?) async throws -> Bool {
            let script = id.map { """
                const r = document.getElementById('\($0)').getBoundingClientRect();
                const x = r.left + Math.min(r.width / 2, 180), y = r.top + Math.min(r.height / 2, 30);
                document.elementFromPoint(x, y).dispatchEvent(new PointerEvent('pointermove', { clientX: x, clientY: y, bubbles: true }));
                """
            } ?? "document.body.dispatchEvent(new PointerEvent('pointerout', { bubbles: true, relatedTarget: null }));"
            _ = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            return readiness.isPointerOverSidewaysScroller
        }
    }

    @Test(arguments: ["wide", "long"])
    func aTableWiderThanTheColumnScrollsSideways(_ id: String) async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        #expect(try await page.pointer(over: id))
    }

    /// Code in cells wraps at its spaces like other text: the table scrolls only when its longest
    /// words still do not fit, and the report follows the wrapper.
    @Test func codeInCellsIsReportedExactlyWhenItsTableOverflows() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        let overflows = try await page.webView.callAsyncJavaScript(
            "const w = document.getElementById('code').parentElement; return w.scrollWidth > w.clientWidth + 1;",
            arguments: [:], in: nil, contentWorld: .page) as? Bool
        #expect(try await page.pointer(over: "code") == (overflows == true))
    }

    @Test(arguments: ["tall", "small", "text"])
    func aTableThatFitsAndPlainTextDoNot(_ id: String) async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        #expect(try await page.pointer(over: id) == false)
    }

    @Test func movingOffTheTableOrThePageClearsTheReport() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        #expect(try await page.pointer(over: "wide"))
        #expect(try await page.pointer(over: "small") == false)
        #expect(try await page.pointer(over: "long"))
        #expect(try await page.pointer(over: nil) == false)
    }

    /// A code block or diff drawn in a shadow root (@pierre/diffs in the agent chat): the box that
    /// scrolls sideways is inside it, where `document.elementFromPoint` does not reach.
    @Test func aScrollerInsideAShadowRootScrollsSideways() async throws {
        let page = Page()
        defer { page.window.closeAfterTest() }
        await page.load()
        #expect(try await page.pointer(over: "shadowWide"))
        #expect(try await page.pointer(over: "shadowFits") == false)
    }
}
