import CmuxAgentChat
import Foundation

/// Loads the bundled markdown web renderer assets from the app bundle's
/// `markdown-viewer` directory — the same shell, marked.js, highlight.js, and
/// GitHub CSS the macOS panel renders with, copied into the iOS app by its
/// resources build phase.
///
/// Unlike the macOS loader this one is non-fatal: when the host app does not
/// bundle the assets (unit-test hosts, previews), `isAvailable` is false and
/// callers fall back to the native block renderer.
@MainActor
final class MarkdownWebViewerAssets {
    static let shared = MarkdownWebViewerAssets(bundle: .main)

    private let bundle: Bundle
    private var cache: [String: String] = [:]
    private var cachedShellHTML: String??

    /// True when every asset the shell template splices in is present.
    let isAvailable: Bool

    /// True when the spliced shell actually loads and decodes, so choosing the
    /// web renderer can never strand the reader on a blank pane when an asset
    /// is present but corrupt. The result (including the spliced shell) is
    /// computed once and cached.
    var isUsable: Bool {
        shellHTML() != nil
    }

    init(bundle: Bundle) {
        self.bundle = bundle
        isAvailable = Self.requiredAssets.allSatisfy { name, ext in
            Self.assetURL(name: name, ext: ext, bundle: bundle) != nil
        }
    }

    private static let requiredAssets: [(String, String)] = [
        ("shell", "html"),
        ("marked.min", "js"),
        ("highlight.min", "js"),
        ("highlight-github", "css"),
        ("highlight-github-dark", "css"),
        ("github-markdown", "css"),
        ("viewer-navigation", "js"),
    ]

    func shellHTML() -> String? {
        if let cachedShellHTML {
            return cachedShellHTML
        }
        let spliced = splicedShellHTML()
        cachedShellHTML = spliced
        return spliced
    }

    private func splicedShellHTML() -> String? {
        guard isAvailable,
              let shell = asset(name: "shell", ext: "html"),
              let githubCSS = asset(name: "github-markdown", ext: "css"),
              let highlightLight = asset(name: "highlight-github", ext: "css"),
              let highlightDark = asset(name: "highlight-github-dark", ext: "css"),
              let marked = asset(name: "marked.min", ext: "js"),
              let highlight = asset(name: "highlight.min", ext: "js"),
              let viewerNavigation = asset(name: "viewer-navigation", ext: "js") else {
            return nil
        }
        return shell
            .replacingOccurrences(of: "{{githubMarkdownCSS}}", with: githubCSS)
            .replacingOccurrences(of: "{{highlightLightCSS}}", with: highlightLight)
            .replacingOccurrences(of: "{{highlightDarkCSS}}", with: highlightDark)
            .replacingOccurrences(of: "{{markedJS}}", with: marked)
            .replacingOccurrences(of: "{{highlightJS}}", with: highlight)
            .replacingOccurrences(of: "{{viewerNavigationJS}}", with: viewerNavigation)
            .replacingOccurrences(of: "{{localizedStringsJSON}}", with: Self.localizedStringsJSON())
    }

    /// Load and cache a bundled asset on demand (mermaid / vega lazy libs).
    func asset(name: String, ext: String) -> String? {
        let key = "\(name).\(ext)"
        if let cached = cache[key] {
            return cached
        }
        guard let url = Self.assetURL(name: name, ext: ext, bundle: bundle),
              let source = Self.loadAsset(url: url) else {
            return nil
        }
        cache[key] = source
        return source
    }

    /// Off-main variant for the multi-megabyte lazy diagram libraries, so the
    /// first mermaid/vega render doesn't inflate them on the main actor.
    /// Returns nil when any requested asset is missing or corrupt.
    func assets(_ specs: [(name: String, ext: String)]) async -> [String]? {
        var sources: [String] = []
        for spec in specs {
            let key = "\(spec.name).\(spec.ext)"
            if let cached = cache[key] {
                sources.append(cached)
                continue
            }
            guard let url = Self.assetURL(name: spec.name, ext: spec.ext, bundle: bundle) else {
                return nil
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                Self.loadAsset(url: url)
            }.value
            guard let loaded else { return nil }
            cache[key] = loaded
            sources.append(loaded)
        }
        return sources
    }

    private nonisolated static func assetURL(name: String, ext: String, bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: "\(ext).deflate", subdirectory: "markdown-viewer")
            ?? bundle.url(forResource: name, withExtension: "\(ext).deflate")
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "markdown-viewer")
            ?? bundle.url(forResource: name, withExtension: ext)
    }

    private nonisolated static func loadAsset(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.lastPathComponent.hasSuffix(".deflate") {
            guard let inflated = MarkdownViewerAssetCompression.inflate(data) else { return nil }
            return String(data: inflated, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Same keys and copy as the macOS viewer; localized from this package's
    /// string catalog so the shell's remote-image consent UI reads correctly.
    private static func localizedStringsJSON() -> String {
        let strings = [
            "remoteImageBlocked": String(
                localized: "markdown.web.remoteImageBlocked",
                defaultValue: "Remote image blocked",
                bundle: .module
            ),
            "remoteImageConsentMessage": String(
                localized: "markdown.web.remoteImageConsentMessage",
                defaultValue: "cmux will not contact this image URL until you load this image.",
                bundle: .module
            ),
            "remoteImageLoadImage": String(
                localized: "markdown.web.remoteImageLoadImage",
                defaultValue: "Load this image",
                bundle: .module
            ),
            "remoteImageLoading": String(
                localized: "markdown.web.remoteImageLoading",
                defaultValue: "Loading",
                bundle: .module
            ),
            "remoteImageHTTPSOnly": String(
                localized: "markdown.web.remoteImageHTTPSOnly",
                defaultValue: "Only HTTPS remote images can be loaded in the viewer.",
                bundle: .module
            ),
            "remoteImageCopyURL": String(
                localized: "markdown.web.remoteImageCopyURL",
                defaultValue: "Copy image URL",
                bundle: .module
            ),
            "remoteImageCopied": String(
                localized: "markdown.web.remoteImageCopied",
                defaultValue: "Copied",
                bundle: .module
            ),
            "remoteImageOpenURL": String(
                localized: "markdown.web.remoteImageOpenURL",
                defaultValue: "Open image URL",
                bundle: .module
            ),
            "remoteImageNotAllowed": String(
                localized: "markdown.web.remoteImageNotAllowed",
                defaultValue: "This remote image URL cannot be loaded in the viewer.",
                bundle: .module
            ),
            "remoteImageURL": String(
                localized: "markdown.web.remoteImageURL",
                defaultValue: "Image URL: {url}",
                bundle: .module
            )
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
