import AppKit
@testable import CmuxNextPages
import Testing
import WebKit

/// The floating Chief is a React page in a window of its own that moves by its background (user 2026-11-09: "it
/// should be raycast-type floating window"; drags on empty space in the real chat must move it). The page reports a
/// press that starts a drag (``PageTitleRowPress``) anywhere, saying whether it was on content (text, media) or on
/// empty space; controls, links and `data-no-drag` keep their presses as on the title row. A real WebKit page with
/// a message, a link and empty space; presses are DOM mouse events at real layout points.
@MainActor @Suite(.serialized) struct PageBackgroundPressScriptTests {
    static let html = """
    <html><body style="margin:0;height:600px;font:16px -apple-system">
    <p id="text" style="position:absolute;left:20px;top:200px;margin:0">Is the build green?</p>
    <a id="link" href="https://example.com" style="position:absolute;left:20px;top:260px">PR 1</a>
    <img id="pic" style="position:absolute;left:20px;top:320px;width:60px;height:40px;background:#888">
    <div id="keep" data-no-drag style="position:absolute;left:200px;top:320px;width:60px;height:40px"></div>
    </body></html>
    """

    final class Sink: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var reports: [PageTitleRowPress.Report] = []
        var loaded: CheckedContinuation<Void, Never>?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let report = PageTitleRowPress.Report(message.body) { reports.append(report) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    }

    static func page() async -> (WKWebView, Sink) {
        let sink = Sink()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(PageTitleRowPress.userScript)
        configuration.userContentController.add(sink, contentWorld: .page, name: PageTitleRowPress.handlerName)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), configuration: configuration)
        web.navigationDelegate = sink
        await withCheckedContinuation { continuation in
            sink.loaded = continuation
            web.loadHTMLString(html, baseURL: nil)
        }
        return (web, sink)
    }

    /// Presses at the middle of `selector`'s box (or at `x`,`y`) and moves 10 px: the report it posts, if any.
    static func press(_ web: WKWebView, _ sink: Sink, at selector: String? = nil, x: Double = 0, y: Double = 0) async throws -> PageTitleRowPress.Report? {
        sink.reports = []
        let point = selector.map { "const r = document.querySelector('\($0)').getBoundingClientRect(); const x = r.left + r.width / 2, y = r.top + r.height / 2;" }
            ?? "const x = \(x), y = \(y);"
        _ = try await web.callAsyncJavaScript("""
            \(point)
            const target = document.elementFromPoint(x, y) || document.body;
            target.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, clientX: x, clientY: y, button: 0, buttons: 1, detail: 1 }));
            target.dispatchEvent(new MouseEvent("mousemove", { bubbles: true, clientX: x + 10, clientY: y, buttons: 1 }));
            await new Promise((done) => setTimeout(done, 0));
            """, contentWorld: .page)
        // The message posts before the script's promise resolves: WebKit delivers it first. The script waits a
        // timer turn, not a frame: a page outside a window draws none.
        return sink.reports.last
    }

    @Test func aPressReportsWhetherItIsOnEmptySpaceOrOnContent() async throws {
        let (web, sink) = await Self.page()
        let empty = try #require(try await Self.press(web, sink, x: 300, y: 450), "a drag on empty space is not reported")
        #expect(empty.kind == .drag && !empty.onContent, "empty space reads as content: \(empty)")
        let text = try #require(try await Self.press(web, sink, at: "#text"), "a drag on text is not reported")
        #expect(text.onContent, "a drag on a message's text reads as empty space (it would move the window, not select)")
        let pic = try #require(try await Self.press(web, sink, at: "#pic"))
        #expect(pic.onContent, "a drag on a picture reads as empty space")
        #expect(try await Self.press(web, sink, at: "#link") == nil, "a link's press was reported")
        #expect(try await Self.press(web, sink, at: "#keep") == nil, "a data-no-drag press was reported")
        let row = try #require(try await Self.press(web, sink, x: 300, y: 20), "a drag on the title row is not reported")
        #expect(!row.onContent)
    }
}
