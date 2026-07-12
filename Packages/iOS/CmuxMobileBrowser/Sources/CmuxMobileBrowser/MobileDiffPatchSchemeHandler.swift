#if canImport(UIKit)
import Foundation
import WebKit

/// Serves immutable local diff content entirely within WebKit's synchronous callback.
@MainActor
final class MobileDiffPatchSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "cmux-mobile-diff-data"
    static var assetsAvailable: Bool {
        guard let resourceURL = Bundle.main.resourceURL else { return false }
        return (try? resourceURL.appendingPathComponent("webviews-app/main.mjs").checkResourceIsReachable()) == true
            && (try? resourceURL.appendingPathComponent("diff-viewer/diffs.mjs").checkResourceIsReachable()) == true
    }

    private let store = MobileDiffPatchStore()

    func configure(generation: Int, html: Data, patch: Data) {
        store.configure(generation: generation, html: html, patch: patch)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "viewer" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard let content = store.content(for: url.path) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "\(content.mimeType); charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff",
                "Cross-Origin-Resource-Policy": "same-origin",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(content.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
#endif
