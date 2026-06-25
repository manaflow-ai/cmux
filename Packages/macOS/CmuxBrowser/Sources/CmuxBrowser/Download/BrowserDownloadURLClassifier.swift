public import Foundation
internal import UniformTypeIdentifiers

/// Pure URL classification for the browser context-menu download and copy paths.
///
/// Lifted byte-faithfully out of the app-target `CmuxWebView` so the scheme,
/// favicon, image-detection, Google-redirect, and MIME-inference predicates that
/// decide whether a right-clicked link or image can be downloaded/copied live in
/// `CmuxBrowser` beside `BrowserDataURLPayload` and `BrowserDownloadFilenameResolver`.
///
/// Every method is a deterministic transform over the URL's scheme, host, query,
/// path extension, and (for `data:` URLs) the decoded `BrowserDataURLPayload`,
/// with zero instance reference state. The image file-extension set and the
/// image-format query-token list are the only state, held as stored value
/// properties, so this is a real instance value type, not a static-only namespace
/// of utilities: callers construct `BrowserDownloadURLClassifier()` and call
/// `isLikelyImageURL(url)` etc. A pure value type with only `Sendable` stored
/// state, so it is `Sendable` and `nonisolated`.
public nonisolated struct BrowserDownloadURLClassifier: Sendable {
    /// Lowercased file extensions that mark a URL path as an image.
    private let imageFileExtensions: Set<String>

    /// Lowercased query-substring tokens that mark a URL as an image (Google image
    /// search wrappers and `format=` hints).
    private let imageFormatQueryTokens: [String]

    /// Creates a classifier with the default image extension set and query tokens.
    public init() {
        imageFileExtensions = [
            "jpg", "jpeg", "png", "webp", "gif", "bmp",
            "svg", "avif", "heic", "heif", "tif", "tiff", "ico",
        ]
        imageFormatQueryTokens = [
            "imgurl=",
            "mediaurl=",
            "encrypted-tbn",
            "format=jpg",
            "format=jpeg",
            "format=png",
            "format=webp",
            "format=gif",
        ]
    }

    /// Whether the URL uses a scheme cmux can download directly (`http`, `https`,
    /// `file`).
    public func isDownloadableScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    /// Whether the URL is a `data:` URL.
    public func isDataURLScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "data"
    }

    /// Whether the URL is in a scheme cmux supports for download (downloadable or
    /// `data:`).
    public func isDownloadSupportedScheme(_ url: URL) -> Bool {
        return isDownloadableScheme(url) || isDataURLScheme(url)
    }

    /// Unwraps a Google image-search / redirect URL to its underlying target, or
    /// `nil` when the URL is not a Google redirect wrapper.
    public func resolveGoogleRedirectURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("google.") else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = comps.queryItems else { return nil }
        let map = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name.lowercased(), $0.value ?? "") })
        let candidates = ["imgurl", "mediaurl", "url", "q"]
        for key in candidates {
            guard let raw = map[key], !raw.isEmpty,
                  let decoded = raw.removingPercentEncoding ?? raw as String?,
                  let candidate = URL(string: decoded),
                  isDownloadableScheme(candidate) else {
                continue
            }
            return candidate
        }
        // Some links are wrapped as /url?...
        if comps.path.lowercased() == "/url" {
            for key in ["url", "q"] {
                if let raw = map[key], let candidate = URL(string: raw), isDownloadableScheme(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// The Google-redirect-unwrapped URL when applicable, otherwise the URL
    /// unchanged.
    public func normalizedLinkedDownloadURL(_ url: URL) -> URL {
        resolveGoogleRedirectURL(url) ?? url
    }

    /// Whether the URL is likely a favicon (by `favicon` substring or last-path
    /// component prefix).
    public func isLikelyFaviconURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        if lower.contains("favicon") { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("favicon")
    }

    /// Whether the URL is likely an image, by `data:` MIME prefix, path extension,
    /// or image-format query token.
    public func isLikelyImageURL(_ url: URL) -> Bool {
        if isDataURLScheme(url) {
            guard let parsed = BrowserDataURLPayload(url: url),
                  let mime = parsed.mimeType?.lowercased() else {
                return false
            }
            return mime.hasPrefix("image/")
        }
        guard isDownloadableScheme(url) else { return false }
        let ext = url.pathExtension.lowercased()
        if imageFileExtensions.contains(ext) {
            return true
        }
        let lower = url.absoluteString.lowercased()
        for token in imageFormatQueryTokens where lower.contains(token) {
            return true
        }
        return false
    }

    /// The preferred image MIME type inferred from the URL's path extension, or
    /// `nil` when the extension is empty or not an image type.
    public func inferredImageMIMEType(from url: URL) -> String? {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) else {
            return nil
        }
        return type.preferredMIMEType
    }
}
