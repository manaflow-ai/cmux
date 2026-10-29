import Foundation
import Testing
import WebKit
@testable import CmuxBrowser

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
final class BrowserEvaluationScriptTests: NSObject, WKNavigationDelegate {
    private let webView = WKWebView()
    private let service = BrowserControlService()
    private var navigation: AsyncThrowingStream<Void, any Error>.Continuation?

    @Test(arguments: [
        "new DOMRect(1, 2, 3, 4)",
        "new DOMRectReadOnly(1, 2, 3, 4)",
        "Promise.resolve(new DOMRect(1, 2, 3, 4))",
        "({rect: new DOMRect(1, 2, 3, 4)}).rect",
        "(() => { const frame = document.querySelector('iframe'); return new frame.contentWindow.DOMRect(1, 2, 3, 4); })()",
        "document.querySelector('#geometry').getBoundingClientRect()"
    ])
    func rectanglesCrossWebKitAsGeometry(script: String) async throws {
        try await loadPage()
        let result = try await evaluate(script)
        let rect = try #require(result["__cmux_v"] as? [String: Double])
        #expect(rect == ["x": 1, "y": 2, "width": 3, "height": 4, "top": 2, "right": 4, "bottom": 6, "left": 1])
    }

    @Test(arguments: [
        "({rect: new DOMRect(1, 2, 3, 4), items: [new DOMRectReadOnly(1, 2, 3, 4)]})",
        "document.querySelector('iframe').contentWindow.eval('({rect: new DOMRect(1, 2, 3, 4), items: [new DOMRectReadOnly(1, 2, 3, 4)]})')",
        "(() => { const rect = new DOMRect(1, 2, 3, 4); return {rect, items: [rect]}; })()",
        "(() => { class Result { constructor() { this.rect = new DOMRect(1, 2, 3, 4); this.items = [this.rect]; } } return new Result(); })()"
    ])
    func nestedRectanglesAndRepeatedReferences(script: String) async throws {
        try await loadPage()
        let result = try await evaluate(script)
        let value = try #require(result["__cmux_v"] as? [String: Any])
        let rect = try #require(value["rect"] as? [String: Double])
        let items = try #require(value["items"] as? [[String: Double]])
        #expect(rect == ["x": 1, "y": 2, "width": 3, "height": 4, "top": 2, "right": 4, "bottom": 6, "left": 1])
        #expect(items == [rect])
    }

    @Test(arguments: [
        "({zero: 0, text: 'ordinary', flag: false, empty: null, nested: [1, 'two', {}]})",
        "[null, undefined, , 3]",
        "JSON.parse('{\"__proto__\": {\"value\": 42}}')",
        "(() => { const value = {a: 1}; return [value, value]; })()",
        "new Date('2026-01-01T00:00:00Z')",
        "null",
        "undefined"
    ])
    func ordinaryValuesMatchExistingBridge(script: String) async throws {
        try await loadPage()
        let baseline = """
        const value = eval(\(service.jsonLiteral(script)));
        return {__cmux_t: typeof value === 'undefined' ? 'undefined' : 'value', __cmux_v: value};
        """
        let expected = try #require(try await webView.callAsyncJavaScript(
            baseline, arguments: [:], in: nil, contentWorld: .page
        ) as? NSDictionary)
        let result = try await evaluate(script)
        #expect(NSDictionary(dictionary: result) == expected)
    }

    @Test(arguments: [
        "throw new Error('eval failed')",
        "Promise.reject(new Error('promise failed'))",
        "(() => { const value = {}; value.self = value; return value; })()",
        "(() => { const value = []; value.push(value); return value; })()",
        "({get rect() { throw new Error('getter failed'); }})"
    ])
    func errorsReturnNormallyAndNextEvaluationSucceeds(script: String) async throws {
        try await loadPage()
        await #expect(throws: (any Error).self) {
            _ = try await self.evaluate(script)
        }
        let next = try await evaluate("6 * 7")
        #expect(next["__cmux_v"] as? Int == 42)
    }

    @Test func trustedExpressionAndSelectedDocumentUseTheSameWrapper() async throws {
        try await loadPage()
        let result = try await evaluate(
            "document.querySelector('#geometry').getBoundingClientRect()",
            useEval: false,
            frameSelector: "iframe"
        )
        let rect = try #require(result["__cmux_v"] as? [String: Double])
        #expect(rect["x"] == 11)
        #expect(rect["y"] == 12)
    }

    private func evaluate(
        _ script: String,
        useEval: Bool = true,
        frameSelector: String? = nil
    ) async throws -> [String: Any] {
        let body = service.evaluationScript(script: script, useEval: useEval, frameSelector: frameSelector)
        let result = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        return try #require(result as? [String: Any])
    }

    private func loadPage() async throws {
        let (events, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        navigation = continuation
        webView.navigationDelegate = self
        webView.loadHTMLString("""
            <div id="geometry" style="position:fixed;left:1px;top:2px;width:3px;height:4px"></div>
            <iframe srcdoc="<div id='geometry' style='position:fixed;left:11px;top:12px;width:3px;height:4px'></div>"></iframe>
            """, baseURL: nil)
        for try await _ in events {}
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        self.navigation?.finish()
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        self.navigation?.finish(throwing: error)
        self.navigation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        self.navigation?.finish(throwing: error)
        self.navigation = nil
    }
}
