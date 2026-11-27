import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing
import WebKit

/// The gesture-free paths of WebKit (`WebKitGestureFreeEvaluation`). The first one, the
/// content-world SPI, is missing on macOS 14 (fleet probe 2026-10-24), and every cmux script that
/// must not hand the page an activation failed there: design mode stayed on, `cmux browser` input
/// stopped waiting, favicons, scroll, Page Info, the history probe and verification fill stopped.
/// Each path runs here alone (the others left out through the seam, as on an older macOS); each
/// answers and leaves the page without activation.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct WebKitGestureFreeEvaluationTests {
    private static let all: [(WebKitGestureFreeEvaluation.Path, Selector)] = [
        (.contentWorld, WebKitGestureFreeEvaluation.contentWorldSelector),
        (.asyncFunction, WebKitGestureFreeEvaluation.asyncFunctionSelector),
        (.pageWorld, WebKitGestureFreeEvaluation.pageWorldSelector),
    ]

    /// Only `path`'s selector allowed.
    private static func only(_ path: WebKitGestureFreeEvaluation.Path) -> (Selector) -> Bool {
        let selector = all.first { $0.0 == path }?.1
        return { $0 == selector }
    }

    /// macOS 14's set: no content-world SPI.
    @Test func withoutTheContentWorldSPIScriptsTakeTheAsyncFunctionPath() async throws {
        let view = try await Self.loadedView()
        let macOS14 = WebKitGestureFreeEvaluation(webView: view) { $0 != WebKitGestureFreeEvaluation.contentWorldSelector }
        #expect(macOS14.path(in: .page) == .asyncFunction)
        #expect(macOS14.path(in: .defaultClient) == .asyncFunction)
        #expect(macOS14.functionPath() == .asyncFunction)
    }

    @Test(arguments: [WebKitGestureFreeEvaluation.Path.contentWorld, .asyncFunction, .pageWorld])
    func eachPathAnswersWithoutActivatingThePage(_ path: WebKitGestureFreeEvaluation.Path) async throws {
        let view = try await Self.loadedView()
        let evaluation = WebKitGestureFreeEvaluation(webView: view, allows: Self.only(path))
        try #require(evaluation.path(in: .page) == path, "this WebKit has no \(path) path")
        #expect(try await evaluation.evaluate("6 * 7", in: .page) == .number(42))
        if path == .pageWorld {
            await #expect(throws: BrowserTabError.self) { try await evaluation.evaluate("1", in: .defaultClient) }
        } else {
            #expect(try await evaluation.evaluate("document.title", in: .defaultClient) == .string("spi"))
        }
        #expect(try await Self.hasBeenActive(view) == false, "the \(path) path gave the page an activation")
    }

    @Test func aFunctionCallTakesArgumentsWithoutActivatingThePage() async throws {
        let view = try await Self.loadedView()
        let evaluation = WebKitGestureFreeEvaluation(webView: view, allows: Self.only(.asyncFunction))
        #expect(try await evaluation.callAsync("return a + b", arguments: ["a": 2, "b": 3], in: .defaultClient) == .number(5))
        #expect(try await Self.hasBeenActive(view) == false)
    }

    @Test func withNoPathTheCallThrowsAndRunsNothing() async throws {
        let view = try await Self.loadedView()
        let none = WebKitGestureFreeEvaluation(webView: view) { _ in false }
        await #expect(throws: BrowserTabError.self) { try await none.evaluate("window.ran = true", in: .page) }
        await #expect(throws: BrowserTabError.self) { try await none.callAsync("window.ran = true", arguments: [:], in: .page) }
        #expect(try await WebKitGestureFreeEvaluation(webView: view).evaluate("window.ran === true", in: .page) == .bool(false))
    }

    private static func loadedView() async throws -> WKWebView {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.loadHTMLString("<!doctype html><title>spi</title><p>spi</p>", baseURL: nil)
        let any = WebKitGestureFreeEvaluation(webView: view)
        // The title too: the empty initial document is already `complete` before the HTML load commits, and a
        // test that reads `document.title` there gets "".
        for _ in 0..<600 {
            if (try? await any.evaluate("document.readyState === 'complete' && document.title === 'spi'", in: .page)) == .bool(true) {
                return view
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw BrowserTabError.timedOut("load")
    }

    private static func hasBeenActive(_ view: WKWebView) async throws -> Bool {
        try await WebKitGestureFreeEvaluation(webView: view).evaluate("navigator.userActivation.hasBeenActive", in: .page) == .bool(true)
    }
}
