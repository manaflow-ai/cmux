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
    private var requestTasks: [ObjectIdentifier: (token: UUID, task: Task<Void, Never>)] = [:]

    func configure(generation: Int, html: Data, patch: Data) async {
        await store.configure(generation: generation, html: html, patch: patch)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "viewer" else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let requestID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let token = UUID()
        requestTasks.removeValue(forKey: requestID)?.task.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let content = await store.content(for: url.path) else {
                guard isActive(requestID, token: token) else { return }
                urlSchemeTask.didFailWithError(URLError(.badURL))
                finish(requestID, token: token)
                return
            }
            guard isActive(requestID, token: token) else { return }
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
            guard isActive(requestID, token: token) else { return }
            urlSchemeTask.didReceive(content.data)
            guard isActive(requestID, token: token) else { return }
            urlSchemeTask.didFinish()
            finish(requestID, token: token)
        }
        requestTasks[requestID] = (token, task)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        requestTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.task.cancel()
    }

    func cancelAll() {
        let tasks = requestTasks.values.map(\.task)
        requestTasks.removeAll()
        for task in tasks { task.cancel() }
    }

    private func isActive(_ requestID: ObjectIdentifier, token: UUID) -> Bool {
        requestTasks[requestID]?.token == token && !Task.isCancelled
    }

    private func finish(_ requestID: ObjectIdentifier, token: UUID) {
        guard requestTasks[requestID]?.token == token else { return }
        requestTasks[requestID] = nil
    }
}
#endif
