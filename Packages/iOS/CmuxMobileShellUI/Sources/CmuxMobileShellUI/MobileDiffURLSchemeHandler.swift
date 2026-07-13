#if os(iOS)
import Foundation
@preconcurrency import WebKit

/// Serves the bundled viewer assets and a streamed RPC-backed patch response.
@MainActor
final class MobileDiffURLSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "cmux-mobile-diff"

    let origin: URL
    private let service: MobileDiffRPCService
    private let paths: [String]
    private let hostPage: MobileDiffHostPage
    private let onTooLargePaths: ([String]) -> Void
    private let bundleRoot: URL?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        service: MobileDiffRPCService,
        paths: [String],
        layout: MobileDiffHostPage.Layout,
        title: String,
        labels: [String: String],
        onTooLargePaths: @escaping ([String]) -> Void
    ) {
        let host = UUID().uuidString.lowercased()
        origin = URL(string: "\(Self.scheme)://\(host)")!
        self.service = service
        self.paths = paths
        hostPage = MobileDiffHostPage(
            origin: origin,
            layout: layout,
            title: title,
            labels: labels
        )
        self.onTooLargePaths = onTooLargePaths
        bundleRoot = Bundle.main.resourceURL?
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == Self.scheme,
              url.host == origin.host else {
            urlSchemeTask.didFailWithError(Self.notFoundError)
            return
        }
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { tasks[identifier] = nil }
            do {
                switch url.path {
                case "/", "/index.html":
                    try send(
                        data: hostPage.htmlData(),
                        mimeType: "text/html",
                        url: url,
                        identifier: identifier,
                        task: urlSchemeTask
                    )
                case "/patch":
                    try await streamPatch(url: url, identifier: identifier, task: urlSchemeTask)
                default:
                    try await sendAsset(url: url, identifier: identifier, task: urlSchemeTask)
                }
            } catch is CancellationError {
                return
            } catch {
                guard isLive(identifier) else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
        tasks[identifier] = task
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        tasks.removeValue(forKey: identifier)?.cancel()
    }

    func cancelAll() {
        let activeTasks = tasks.values
        tasks.removeAll()
        activeTasks.forEach { $0.cancel() }
    }

    private func streamPatch(
        url: URL,
        identifier: ObjectIdentifier,
        task: any WKURLSchemeTask
    ) async throws {
        guard isLive(identifier) else { throw CancellationError() }
        task.didReceive(URLResponse(
            url: url,
            mimeType: "text/x-diff",
            expectedContentLength: -1,
            textEncodingName: "utf-8"
        ))
        for try await chunk in service.patchStream(paths: paths) {
            try Task.checkCancellation()
            guard isLive(identifier) else { throw CancellationError() }
            if !chunk.tooLargePaths.isEmpty {
                onTooLargePaths(chunk.tooLargePaths)
            }
            if !chunk.data.isEmpty {
                task.didReceive(chunk.data)
            }
        }
        guard isLive(identifier) else { throw CancellationError() }
        task.didFinish()
    }

    private func sendAsset(
        url: URL,
        identifier: ObjectIdentifier,
        task: any WKURLSchemeTask
    ) async throws {
        guard let fileURL = assetURL(for: url.path) else { throw Self.notFoundError }
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        }.value
        try send(
            data: data,
            mimeType: MobileDiffMIMEType().value(forPath: fileURL.path),
            url: url,
            identifier: identifier,
            task: task
        )
    }

    private func send(
        data: Data,
        mimeType: String,
        url: URL,
        identifier: ObjectIdentifier,
        task: any WKURLSchemeTask
    ) throws {
        guard isLive(identifier) else { throw CancellationError() }
        task.didReceive(URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
        ))
        if !data.isEmpty {
            task.didReceive(data)
        }
        task.didFinish()
    }

    private func assetURL(for requestPath: String) -> URL? {
        guard let bundleRoot else { return nil }
        let relativePath: String
        if requestPath.hasPrefix("/webviews-app/") {
            relativePath = String(requestPath.dropFirst())
        } else if requestPath.hasPrefix("/diff-viewer/") {
            relativePath = String(requestPath.dropFirst())
        } else {
            return nil
        }
        guard !relativePath.split(separator: "/").contains("..") else { return nil }
        let candidate = bundleRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(bundleRoot.path + "/"),
              FileManager.default.isReadableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func isLive(_ identifier: ObjectIdentifier) -> Bool {
        tasks[identifier] != nil
    }

    private static var notFoundError: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)
    }
}
#endif
