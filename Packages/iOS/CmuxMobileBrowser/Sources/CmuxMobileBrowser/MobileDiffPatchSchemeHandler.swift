#if canImport(UIKit)
import Foundation
import WebKit

/// Safety: mutable payloads are actor-isolated, and the synchronous WebKit
/// callback lifetime is guarded by `MobileDiffSchemeTaskLifetime`.
final class MobileDiffPatchSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "cmux-mobile-diff-data"
    static var assetsAvailable: Bool {
        guard let resourceURL = Bundle.main.resourceURL else { return false }
        return (try? resourceURL.appendingPathComponent("webviews-app/main.mjs").checkResourceIsReachable()) == true
            && (try? resourceURL.appendingPathComponent("diff-viewer/diffs.mjs").checkResourceIsReachable()) == true
    }

    private let store = MobileDiffPatchStore()
    private let taskLifetime = MobileDiffSchemeTaskLifetime()

    func configure(generation: Int, html: Data, patch: Data) async {
        await store.configure(generation: generation, html: html, patch: patch)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "viewer" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let requestID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let pendingTask = MobileDiffPendingSchemeTask(urlSchemeTask)
        taskLifetime.register(requestID)
        Task { [store, taskLifetime] in
            guard let content = await store.content(for: url.path) else {
                _ = taskLifetime.performCallback(requestID) { pendingTask.fail(with: URLError(.badURL)) }
                taskLifetime.finish(requestID)
                return
            }
            _ = taskLifetime.performCallback(requestID) { pendingTask.finish(url: url, content: content) }
            taskLifetime.finish(requestID)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        taskLifetime.stop(ObjectIdentifier(urlSchemeTask as AnyObject))
    }
}
#endif
