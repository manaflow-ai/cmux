import Foundation
import WebKit

final class IssueInboxURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-issue-inbox"
    static let host = "shell"

    private static let textualExtensions: Set<String> = ["html", "mjs", "js", "css", "json", "svg", "map"]

    private let fileManager: FileManager
    private let rootURL: URL
    private let rootPath: String

    override convenience init() {
        let resourceURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/", isDirectory: true)
        self.init(
            rootURL: resourceURL
                .appendingPathComponent("markdown-viewer", isDirectory: true)
                .appendingPathComponent("webviews-app", isDirectory: true),
            fileManager: .default
        )
    }

    init(rootURL: URL, fileManager: FileManager) {
        self.fileManager = fileManager
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootPath = self.rootURL.path
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            let requestURL = try validatedRequestURL(urlSchemeTask.request.url)
            let file = try resolvedFile(for: requestURL)
            let data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": contentType(mimeType: file.mimeType, pathExtension: file.pathExtension),
                    "Content-Length": String(data.count),
                ]
            ) else {
                throw URLError(.badServerResponse)
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func validatedRequestURL(_ url: URL?) throws -> URL {
        guard let url,
              url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              url.query == nil,
              url.fragment == nil,
              !url.path.isEmpty else {
            throw URLError(.fileDoesNotExist)
        }
        let relativePath = String(url.path.dropFirst())
        guard !relativePath.isEmpty,
              !relativePath.contains("\0"),
              Self.isSafeRelativePath(relativePath) else {
            throw URLError(.fileDoesNotExist)
        }
        return url
    }

    private func resolvedFile(for url: URL) throws -> (url: URL, mimeType: String, pathExtension: String) {
        let relativePath = String(url.path.dropFirst())
        let fileURL = rootURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isInsideRoot(fileURL) else {
            throw URLError(.fileDoesNotExist)
        }
        let pathExtension = fileURL.pathExtension.lowercased()
        guard let mimeType = Self.mimeType(forExtension: pathExtension) else {
            throw URLError(.fileDoesNotExist)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: fileURL.path) else {
            throw URLError(.fileDoesNotExist)
        }
        return (fileURL, mimeType, pathExtension)
    }

    private func isInsideRoot(_ fileURL: URL) -> Bool {
        let path = fileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func contentType(mimeType: String, pathExtension: String) -> String {
        if Self.textualExtensions.contains(pathExtension) {
            return "\(mimeType); charset=utf-8"
        }
        return mimeType
    }

    private static func mimeType(forExtension pathExtension: String) -> String? {
        switch pathExtension {
        case "html":
            return "text/html"
        case "mjs", "js":
            return "text/javascript"
        case "css":
            return "text/css"
        case "json", "map":
            return "application/json"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "woff2":
            return "font/woff2"
        default:
            return nil
        }
    }

    private static func isSafeRelativePath(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            let value = String(component)
            return !value.isEmpty && value != "." && value != ".."
        }
    }
}
