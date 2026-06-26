public import Foundation
import UniformTypeIdentifiers

/// Pure URL classification for the browser download and image-copy paths: scheme
/// support, Google image/redirect unwrapping, favicon and image heuristics, and
/// MIME inference. Wraps a single URL; every member is a pure function of that URL
/// with no live browser or webview state.
public struct BrowserDownloadURLClassifier: Sendable {
    /// The URL being classified.
    public let url: URL

    /// Create a classifier for `url`.
    public init(url: URL) {
        self.url = url
    }

    /// `true` when the URL scheme is `http`, `https`, or `file`.
    public var isDownloadableScheme: Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    /// `true` when the URL scheme is `data`.
    public var isDataURLScheme: Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "data"
    }

    /// `true` when the URL is either a downloadable scheme or a data URL.
    public var isDownloadSupportedScheme: Bool {
        return isDownloadableScheme || isDataURLScheme
    }

    /// The underlying target of a Google image/redirect URL (`imgurl`, `mediaurl`,
    /// `url`, `q` query parameters, or a `/url?...` wrapper), or `nil` when the URL
    /// is not a recognized Google redirect.
    public var resolvedGoogleRedirectURL: URL? {
        guard let host = url.host?.lowercased(), host.contains("google.") else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = comps.queryItems else { return nil }
        let map = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name.lowercased(), $0.value ?? "") })
        let candidates = ["imgurl", "mediaurl", "url", "q"]
        for key in candidates {
            guard let raw = map[key], !raw.isEmpty,
                  let decoded = raw.removingPercentEncoding ?? raw as String?,
                  let candidate = URL(string: decoded),
                  BrowserDownloadURLClassifier(url: candidate).isDownloadableScheme else {
                continue
            }
            return candidate
        }
        // Some links are wrapped as /url?...
        if comps.path.lowercased() == "/url" {
            for key in ["url", "q"] {
                if let raw = map[key], let candidate = URL(string: raw), BrowserDownloadURLClassifier(url: candidate).isDownloadableScheme {
                    return candidate
                }
            }
        }
        return nil
    }

    /// The URL with any Google redirect unwrapped, falling back to the original URL.
    public var normalizedLinkedDownloadURL: URL {
        resolvedGoogleRedirectURL ?? url
    }

    /// `true` when the URL looks like a favicon by path or query.
    public var isLikelyFaviconURL: Bool {
        let lower = url.absoluteString.lowercased()
        if lower.contains("favicon") { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("favicon")
    }

    /// `true` when the URL is likely an image, judged by data-URL MIME type, path
    /// extension, or known image-CDN query markers.
    public var isLikelyImageURL: Bool {
        if isDataURLScheme {
            guard let parsed = ParsedDataURL(dataURL: url),
                  let mime = parsed.mimeType?.lowercased() else {
                return false
            }
            return mime.hasPrefix("image/")
        }
        guard isDownloadableScheme else { return false }
        let ext = url.pathExtension.lowercased()
        if [
            "jpg", "jpeg", "png", "webp", "gif", "bmp",
            "svg", "avif", "heic", "heif", "tif", "tiff", "ico"
        ].contains(ext) {
            return true
        }
        let lower = url.absoluteString.lowercased()
        if lower.contains("imgurl=")
            || lower.contains("mediaurl=")
            || lower.contains("encrypted-tbn")
            || lower.contains("format=jpg")
            || lower.contains("format=jpeg")
            || lower.contains("format=png")
            || lower.contains("format=webp")
            || lower.contains("format=gif") {
            return true
        }
        return false
    }

    /// The inferred image MIME type from the URL's path extension, or `nil` when
    /// the extension does not map to an image type.
    public var inferredImageMIMEType: String? {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) else {
            return nil
        }
        return type.preferredMIMEType
    }
}
