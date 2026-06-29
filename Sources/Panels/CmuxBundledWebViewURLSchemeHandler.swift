import Foundation
import WebKit

final class CmuxBundledWebViewURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-webview"
    static let shared = CmuxBundledWebViewURLSchemeHandler()

    private let allowedHosts: Set<String> = ["home"]

    static func homeURL() -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "home"
        components.path = "/home.html"
        return components.url
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.scheme == Self.scheme,
              let host = requestURL.host,
              allowedHosts.contains(host),
              let fileURL = bundledFileURL(for: requestURL),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: requestURL,
            mimeType: Self.mimeType(for: fileURL),
            expectedContentLength: data.count,
            textEncodingName: Self.textEncodingName(for: fileURL)
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func bundledFileURL(for requestURL: URL) -> URL? {
        guard let root = Bundle.main.resourceURL?
            .appendingPathComponent("markdown-viewer/webviews-app", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath() else {
            return nil
        }

        let rawPath = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedPath
            ?? requestURL.path
        guard let decodedPath = rawPath.removingPercentEncoding else { return nil }
        let relativePath = decodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !relativePath.isEmpty,
              relativePath.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let fileURL = relativePath.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        .standardizedFileURL
        .resolvingSymlinksInPath()

        guard fileURL.path == root.path || fileURL.path.hasPrefix(root.path + "/") else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: fileURL.path) else {
            return nil
        }
        return fileURL
    }

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    private static func textEncodingName(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "html", "js", "mjs", "css", "json", "svg":
            return "utf-8"
        default:
            return nil
        }
    }
}
