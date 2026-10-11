import AppKit
import Testing
import WebKit

@testable import CmuxBrowser

@MainActor
@Suite("Browser REPL PDF printing", .serialized)
struct BrowserReplPDFPrinterTests {
    private final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private func longPage() async -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let loaded = Loaded()
        webView.navigationDelegate = loaded
        let body = (0..<200).map { "<p>line \($0) of a page longer than one sheet</p>" }.joined()
        await withCheckedContinuation { continuation in
            loaded.continuation = continuation
            webView.loadHTMLString("<html><body>\(body)</body></html>", baseURL: nil)
        }
        webView.navigationDelegate = nil
        return webView
    }

    private func pageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }

    @Test func printsAPaginatedPDFOfAWebViewInNoWindow() async throws {
        let webView = await longPage()
        #expect(webView.window == nil)
        let data = try await BrowserReplPDFPrinter(
            paper: CGSize(width: 612, height: 792),
            margins: NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
            printBackground: false
        ).pdf(of: webView)
        #expect(pageCount(data) > 1)
    }

    @Test func leavesTheWebViewsWindowAlone() async throws {
        let webView = await longPage()
        let window = NSWindow(
            contentRect: NSRect(x: -32_000, y: -32_000, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { window.close() }
        var sheets: [NSWindow] = []
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: nil) { note in
            MainActor.assumeIsolated { sheets.append(window) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let data = try await BrowserReplPDFPrinter(
            paper: CGSize(width: 612, height: 792),
            margins: NSEdgeInsets(),
            printBackground: true
        ).pdf(of: webView)
        #expect(pageCount(data) > 1)
        #expect(sheets.isEmpty)
        #expect(window.attachedSheet == nil)
        #expect(webView.window === window)
    }
}
