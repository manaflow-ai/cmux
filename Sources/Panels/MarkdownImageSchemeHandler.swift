import CmuxFoundation
import Foundation
import WebKit

/// Backing `WKURLSchemeHandler` for the markdown renderer's custom image
/// schemes (`cmux-local-image`, `cmux-remote-image`). Owns the in-flight
/// image-load bookkeeping and resolves each request against the local
/// filesystem (scoped to the markdown file's directory) or the remote-image
/// fetcher. The only inbound state it needs is `filePath`, which the renderer
/// coordinator keeps in sync at bind time.
@MainActor
final class MarkdownImageSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Custom URL scheme for local-filesystem image requests, scoped to the
    /// markdown file's own directory.
    nonisolated static let localImageURLScheme = "cmux-local-image"
    /// Custom URL scheme for remote (http/https) image requests proxied through
    /// the renderer's remote-image fetcher.
    nonisolated static let remoteImageURLScheme = "cmux-remote-image"

    /// Absolute path of the markdown file being rendered. Used to scope local
    /// image requests to the file's own directory. Mirrored from the renderer
    /// coordinator whenever it rebinds.
    var filePath: String = ""

    private struct ImageLoadResult {
        let data: Data
        let mimeType: String
    }

    private final class ImageLoad {
        var reader: Task<ImageLoadResult, Never>?
        var sender: Task<Void, Never>?

        func cancel() {
            reader?.cancel()
            sender?.cancel()
        }
    }
    private var imageLoads: [ObjectIdentifier: ImageLoad] = [:]

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL))
            return
        }

        let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
        let load = ImageLoad()
        imageLoads[taskId] = load
        let reader = imageLoadTask(for: requestURL)
        load.reader = reader
        let sender = Task { [weak self, weak load] in
            defer {
                if let load, self?.imageLoads[taskId] === load {
                    self?.imageLoads[taskId] = nil
                }
            }
            let result = await reader.value
            guard !Task.isCancelled else { return }
            let response = URLResponse(
                url: requestURL,
                mimeType: result.mimeType,
                expectedContentLength: result.data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            if !result.data.isEmpty {
                urlSchemeTask.didReceive(result.data)
            }
            urlSchemeTask.didFinish()
        }
        load.sender = sender
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskId = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let load = imageLoads.removeValue(forKey: taskId) else { return }
        load.cancel()
    }

    func cancelImageLoads() {
        let loads = imageLoads.values
        imageLoads.removeAll()
        for load in loads {
            load.cancel()
        }
    }

    func cancelLocalImageLoads() {
        cancelImageLoads()
    }

    private func imageLoadTask(for requestURL: URL) -> Task<ImageLoadResult, Never> {
        let scheme = requestURL.scheme?.lowercased()
        if scheme == Self.localImageURLScheme {
            let fileURL = localImageFileURL(from: requestURL)
            let mimeType = fileURL
                .flatMap { self.localImageMimeType(for: $0.pathExtension) } ?? "image/png"
            return Task.detached(priority: .userInitiated) {
                guard let fileURL,
                      FileManager.default.isReadableFile(atPath: fileURL.path) else {
                    return ImageLoadResult(data: Data(), mimeType: mimeType)
                }
                let data = (try? Data(contentsOf: fileURL)) ?? Data()
                return ImageLoadResult(data: data, mimeType: mimeType)
            }
        }

        if scheme == Self.remoteImageURLScheme {
            let security = MarkdownRemoteImageSecurity(remoteImageURLScheme: Self.remoteImageURLScheme)
            let remoteURL = security.remoteImageURL(from: requestURL)
            return Task.detached(priority: .userInitiated) {
                guard let remoteURL,
                      let fetched = await MarkdownRemoteImageFetcher.fetch(remoteURL, security: security) else {
                    return ImageLoadResult(data: Data(), mimeType: "image/png")
                }
                return ImageLoadResult(data: fetched.data, mimeType: fetched.mimeType)
            }
        }

        return Task.detached {
            ImageLoadResult(data: Data(), mimeType: "image/png")
        }
    }

    private func localImageFileURL(from requestURL: URL) -> URL? {
        guard requestURL.scheme?.lowercased() == Self.localImageURLScheme,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let rawFileURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let fileURL = URL(string: rawFileURL),
              fileURL.isFileURL else {
            return nil
        }

        let markdownFilePath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdownFilePath.isEmpty else {
            return nil
        }

        let markdownDirectory = URL(fileURLWithPath: markdownFilePath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard markdownDirectory.path != "/" else {
            return nil
        }

        let markdownRoot = markdownDirectory.path.hasSuffix("/")
            ? markdownDirectory.path
            : markdownDirectory.path + "/"
        let standardizedURL = fileURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard standardizedURL.path.hasPrefix(markdownRoot),
              localImageMimeType(for: standardizedURL.pathExtension) != nil else {
            return nil
        }
        return standardizedURL
    }

    private func localImageMimeType(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "avif":
            return "image/avif"
        default:
            return nil
        }
    }
}
