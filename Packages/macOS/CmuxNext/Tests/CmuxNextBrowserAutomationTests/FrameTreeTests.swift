@testable import CmuxNextBrowserAutomation
import Foundation
import Testing
import WebKit

/// `frames.list` reads WebKit's frame tree with the root kept on the main actor
/// (no `@unchecked Sendable` box through the continuation): a page with one iframe gives the main
/// frame first, then the iframe under it.
@MainActor
struct FrameTreeTests {
    @Test(.timeLimit(.minutes(1))) func aPageWithAnIframeReadsParentsBeforeChildren() async throws {
        // The `_frames:` SPI is on every macOS the browser host runs on (WebKitPrivateCalls.verifiedMajors).
        try #require(FrameTree.isAvailable)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
        let loaded = LoadWaiter()
        view.navigationDelegate = loaded
        try await loaded.load { view.loadHTMLString("<!doctype html><iframe srcdoc='<p>child</p>'></iframe>", baseURL: nil) }

        let frames = await FrameTree.read(view)
        #expect(frames.count == 2)
        #expect(frames.first?.isMain == true)
        #expect(frames.last?.parentFrameID == frames.first?.frameID)
        view.navigationDelegate = nil
    }
}

/// Resumes once the main document (and so its iframe) has loaded.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var finished: CheckedContinuation<Void, any Error>?

    func load(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            finished = continuation
            start()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        finished?.resume(throwing: error)
        finished = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        finished?.resume(throwing: error)
        finished = nil
    }
}
