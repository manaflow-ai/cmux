import Foundation
import CmuxAgentChat
import WebKit

/// Serves the bundled React AgentSession application from a non-file origin.
@MainActor
final class AgentSessionWebRendererURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "cmux-agent-session"
    nonisolated static let host = "shell"

    private static let textualExtensions: Set<String> = ["html", "mjs", "js", "css", "json", "svg", "map"]

    private let fileManager: FileManager
    private let rootURL: URL
    private let rootPath: String

    override convenience init() {
        let resourceURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/__cmux_missing_resources__", isDirectory: true)
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

    nonisolated static func shellURL() -> URL {
        URL(string: "\(scheme)://\(host)/agent-session.html")!
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            let requestURL = try validatedRequestURL(urlSchemeTask.request.url)
            let resource = try resourceData(for: requestURL)
            guard let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": resource.contentType,
                    "Content-Length": String(resource.data.count)
                ]
            ) else {
                throw URLError(.badServerResponse)
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(resource.data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func resourceURL(for requestURL: URL) throws -> (url: URL, mimeType: String) {
        let validatedURL = try validatedRequestURL(requestURL)
        let file = try resolvedFile(for: validatedURL)
        return (file.url, file.mimeType)
    }

    func resourceData(for requestURL: URL) throws -> (data: Data, contentType: String) {
        let validatedURL = try validatedRequestURL(requestURL)
        let file = try resolvedFile(for: validatedURL)
        let storedData = try Data(contentsOf: file.url, options: [.mappedIfSafe])
        let data: Data
        if file.isDeflated {
            guard let inflated = Data.inflateMarkdownViewerAsset(storedData) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data = inflated
        } else {
            data = storedData
        }
        return (
            data: data,
            contentType: contentType(mimeType: file.mimeType, pathExtension: file.pathExtension)
        )
    }

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

    private func resolvedFile(for url: URL) throws -> (
        url: URL,
        mimeType: String,
        pathExtension: String,
        isDeflated: Bool
    ) {
        let relativePath = String(url.path.dropFirst())
        let requestedURL = rootURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let pathExtension = requestedURL.pathExtension.lowercased()
        guard let mimeType = Self.mimeType(forExtension: pathExtension) else {
            throw URLError(.fileDoesNotExist)
        }

        var candidateURLs: [(url: URL, isDeflated: Bool)] = [(requestedURL, false)]
        if pathExtension == "mjs" || pathExtension == "js" {
            candidateURLs.append((requestedURL.appendingPathExtension("deflate"), true))
        }
        candidateURLs = candidateURLs.map { candidate in
            (candidate.url.standardizedFileURL.resolvingSymlinksInPath(), candidate.isDeflated)
        }
        for candidate in candidateURLs {
            guard isInsideRoot(candidate.url) else {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  fileManager.isReadableFile(atPath: candidate.url.path) else {
                continue
            }
            return (candidate.url, mimeType, pathExtension, candidate.isDeflated)
        }
        throw URLError(.fileDoesNotExist)
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
