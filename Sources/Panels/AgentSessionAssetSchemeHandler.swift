import Foundation
import WebKit

final class AgentSessionAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-agent-session"
    static let shared = AgentSessionAssetSchemeHandler()
    static let shellURL = URL(string: "\(scheme)://app/agent-session.html")!

    private struct Asset {
        let pathComponents: [String]
        let mimeType: String
    }

    private static let assetsByRequestPath: [String: Asset] = [
        "/agent-session.html": Asset(
            pathComponents: ["markdown-viewer", "webviews-app", "agent-session.html"],
            mimeType: "text/html"
        ),
        "/main.mjs": Asset(
            pathComponents: ["markdown-viewer", "webviews-app", "main.mjs"],
            mimeType: "text/javascript"
        ),
        "/chunks/agentSessionSurface.mjs": Asset(
            pathComponents: ["markdown-viewer", "webviews-app", "chunks", "agentSessionSurface.mjs"],
            mimeType: "text/javascript"
        ),
        "/chunks/installWebviewStyles.mjs": Asset(
            pathComponents: ["markdown-viewer", "webviews-app", "chunks", "installWebviewStyles.mjs"],
            mimeType: "text/javascript"
        ),
        "/chunks/vendor.mjs": Asset(
            pathComponents: ["markdown-viewer", "webviews-app", "chunks", "vendor.mjs"],
            mimeType: "text/javascript"
        ),
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == Self.scheme,
              requestURL.host == "app",
              requestURL.query == nil,
              let asset = Self.assetsByRequestPath[requestURL.path],
              let resourceURL = Bundle.main.resourceURL else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let fileURL = asset.pathComponents.reduce(resourceURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let response = URLResponse(
                url: requestURL,
                mimeType: asset.mimeType,
                expectedContentLength: data.count,
                textEncodingName: "utf-8"
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        _ = webView
        _ = urlSchemeTask
    }
}
