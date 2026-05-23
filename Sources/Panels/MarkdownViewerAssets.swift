import Foundation

/// Loads the bundled markdown web renderer assets from Resources/markdown-viewer.
/// The heavy diagram libraries are still read lazily so ordinary markdown files
/// do not pay the Mermaid/Vega I/O cost.
@MainActor
final class MarkdownViewerAssets {
    static let shared = MarkdownViewerAssets()

    private let markedJS: String
    private let highlightJS: String
    private let highlightLightCSS: String
    private let highlightDarkCSS: String
    private let githubMarkdownCSS: String
    private let shellTemplate: String
    private let localizedStringsJSON: String

    private lazy var extensionAssets: MarkdownViewerExtensionHTML = MarkdownViewerExtensionAssetLoader.load()
    private var lazyCache: [String: String] = [:]

    private init() {
        markedJS = MarkdownViewerAssets.loadAsset(name: "marked.min", ext: "js")
        highlightJS = MarkdownViewerAssets.loadAsset(name: "highlight.min", ext: "js")
        highlightLightCSS = MarkdownViewerAssets.loadAsset(name: "highlight-github", ext: "css")
        highlightDarkCSS = MarkdownViewerAssets.loadAsset(name: "highlight-github-dark", ext: "css")
        githubMarkdownCSS = MarkdownViewerAssets.loadAsset(name: "github-markdown", ext: "css")
        shellTemplate = MarkdownViewerAssets.loadAsset(name: "shell", ext: "html")
        localizedStringsJSON = MarkdownViewerAssets.localizedStringsJSON()
    }

    func shellHTML(isDark: Bool) -> String {
        _ = isDark
        return shellTemplate
            .replacingOccurrences(of: "{{githubMarkdownCSS}}", with: githubMarkdownCSS)
            .replacingOccurrences(of: "{{highlightLightCSS}}", with: highlightLightCSS)
            .replacingOccurrences(of: "{{highlightDarkCSS}}", with: highlightDarkCSS)
            .replacingOccurrences(of: "{{extensionStyles}}", with: extensionAssets.stylesHTML)
            .replacingOccurrences(of: "{{markedJS}}", with: markedJS)
            .replacingOccurrences(of: "{{highlightJS}}", with: highlightJS)
            .replacingOccurrences(of: "{{localizedStringsJSON}}", with: localizedStringsJSON)
            .replacingOccurrences(of: "{{extensionScripts}}", with: extensionAssets.scriptsHTML)
    }

    /// Load and cache a bundled JS asset on demand.
    func lazyAsset(name: String, ext: String) -> String {
        let key = "\(name).\(ext)"
        if let cached = lazyCache[key] {
            return cached
        }
        let source = MarkdownViewerAssets.loadAsset(name: name, ext: ext)
        lazyCache[key] = source
        return source
    }

    private static func loadAsset(name: String, ext: String) -> String {
        let bundle = Bundle.main
        let compressedCandidates: [URL?] = [
            bundle.url(forResource: name, withExtension: "\(ext).deflate", subdirectory: "markdown-viewer"),
            bundle.url(forResource: name, withExtension: "\(ext).deflate")
        ]
        for case let url? in compressedCandidates {
            guard let s = loadDeflatedTextAsset(url: url) else {
#if DEBUG
                NSLog("MarkdownViewerAssets: invalid compressed asset \(url.path)")
#endif
                preconditionFailure("Invalid compressed markdown viewer asset \(url.lastPathComponent)")
            }
            return s
        }

        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: ext, subdirectory: "markdown-viewer"),
            bundle.url(forResource: name, withExtension: ext)
        ]
        for case let url? in candidates {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                return s
            }
        }
#if DEBUG
        NSLog("MarkdownViewerAssets: missing bundled asset \(name).\(ext)")
#endif
        preconditionFailure("Missing bundled markdown viewer asset \(name).\(ext)")
    }

    private static func localizedStringsJSON() -> String {
        let strings = [
            "remoteImageBlocked": String(
                localized: "markdown.web.remoteImageBlocked",
                defaultValue: "Remote image blocked"
            ),
            "remoteImageConsentMessage": String(
                localized: "markdown.web.remoteImageConsentMessage",
                defaultValue: "cmux will not contact this image URL until you load this image."
            ),
            "remoteImageLoadImage": String(
                localized: "markdown.web.remoteImageLoadImage",
                defaultValue: "Load this image"
            ),
            "remoteImageLoading": String(
                localized: "markdown.web.remoteImageLoading",
                defaultValue: "Loading"
            ),
            "remoteImageHTTPSOnly": String(
                localized: "markdown.web.remoteImageHTTPSOnly",
                defaultValue: "Only HTTPS remote images can be loaded in the viewer."
            ),
            "remoteImageCopyURL": String(
                localized: "markdown.web.remoteImageCopyURL",
                defaultValue: "Copy image URL"
            ),
            "remoteImageCopied": String(
                localized: "markdown.web.remoteImageCopied",
                defaultValue: "Copied"
            ),
            "remoteImageOpenURL": String(
                localized: "markdown.web.remoteImageOpenURL",
                defaultValue: "Open image URL"
            ),
            "remoteImageNotAllowed": String(
                localized: "markdown.web.remoteImageNotAllowed",
                defaultValue: "This remote image URL cannot be loaded in the viewer."
            ),
            "remoteImageURL": String(
                localized: "markdown.web.remoteImageURL",
                defaultValue: "Image URL: {url}"
            )
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func loadDeflatedTextAsset(url: URL) -> String? {
        guard let compressed = try? Data(contentsOf: url),
              let decompressed = try? (compressed as NSData).decompressed(using: .zlib) as Data else {
            return nil
        }
        return String(data: decompressed, encoding: .utf8)
    }
}

private struct MarkdownViewerExtensionHTML {
    let stylesHTML: String
    let scriptsHTML: String
}

private enum MarkdownViewerExtensionAssetLoader {
    private static let maximumStyleBytes = 256 * 1024
    private static let maximumScriptBytes = 512 * 1024
    private static let maximumTotalBytes = 1024 * 1024
    private static let maximumAssetsPerExtension = 16

    static func load(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MarkdownViewerExtensionHTML {
        let roots = manifestRootCandidates(homeURL: homeURL)
        var seenExtensionIDs = Set<String>()
        var remainingBytes = maximumTotalBytes
        var styles: [String] = []
        var scripts: [String] = []

        for root in roots {
            guard remainingBytes > 0,
                  let manifest = loadManifest(at: root),
                  let markdownViewer = markdownViewerObject(in: manifest) else {
                continue
            }

            let rawID = stringValue(in: manifest, keys: ["id"]) ?? root.lastPathComponent
            let extensionID = sanitizedIdentifier(rawID)
            guard !extensionID.isEmpty else { continue }
            guard seenExtensionIDs.insert(extensionID.lowercased()).inserted else { continue }

            let stylePaths = stringValues(in: markdownViewer, keys: ["styles", "style", "css"])
                .prefix(maximumAssetsPerExtension)
            let scriptPaths = stringValues(in: markdownViewer, keys: ["scripts", "script", "js"])
                .prefix(maximumAssetsPerExtension)

            for path in stylePaths {
                guard remainingBytes > 0,
                      let assetURL = resolvedAssetURL(
                        path,
                        relativeTo: root,
                        allowedExtensions: ["css"]
                      ),
                      let source = readTextAsset(
                        assetURL,
                        maximumBytes: min(maximumStyleBytes, remainingBytes)
                      ),
                      let safeSource = sanitizedStyleSource(source) else {
                    continue
                }
                remainingBytes -= source.utf8.count
                styles.append(styleHTML(extensionID: extensionID, assetPath: path, source: safeSource))
            }

            for path in scriptPaths {
                guard remainingBytes > 0,
                      let assetURL = resolvedAssetURL(
                        path,
                        relativeTo: root,
                        allowedExtensions: ["js", "mjs"]
                      ),
                      let source = readTextAsset(
                        assetURL,
                        maximumBytes: min(maximumScriptBytes, remainingBytes)
                      ) else {
                    continue
                }
                remainingBytes -= source.utf8.count
                scripts.append(scriptHTML(extensionID: extensionID, assetPath: path, source: source))
            }
        }

        return MarkdownViewerExtensionHTML(
            stylesHTML: styles.joined(separator: "\n"),
            scriptsHTML: scripts.joined(separator: "\n")
        )
    }

    private static func manifestRootCandidates(homeURL: URL) -> [URL] {
        var roots: [URL] = []
        roots.append(contentsOf: installedManifestRootCandidates(homeURL: homeURL))
        roots.append(contentsOf: sourceManifestRootCandidates(homeURL: homeURL))
        return roots
    }

    private static func installedManifestRootCandidates(homeURL: URL) -> [URL] {
        let extensionsURL = homeURL
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        let extensionIDs = directoryChildren(at: extensionsURL)
        return extensionIDs.flatMap { extensionURL in
            directoryChildren(at: extensionURL)
                .sorted { lhs, rhs in
                    lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedDescending
                }
        }
    }

    private static func sourceManifestRootCandidates(homeURL: URL) -> [URL] {
        let githubSourcesURL = homeURL
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("extension-sources", isDirectory: true)
            .appendingPathComponent("github.com", isDirectory: true)
        return directoryChildren(at: githubSourcesURL).flatMap { ownerURL in
            directoryChildren(at: ownerURL)
        }
    }

    private static func directoryChildren(at url: URL) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return children
            .filter { isDirectory($0) }
            .sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func loadManifest(at root: URL) -> [String: Any]? {
        for name in ["cmux.extension.json", "cmux-extension.json"] {
            let url = root.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return object
        }
        return nil
    }

    private static func markdownViewerObject(in manifest: [String: Any]) -> [String: Any]? {
        if let contributes = manifest["contributes"] as? [String: Any] {
            if let viewers = contributes["viewers"] as? [String: Any],
               let markdown = viewers["markdown"] as? [String: Any] {
                return markdown
            }
            if let markdown = contributes["markdown"] as? [String: Any] {
                return markdown
            }
            if let markdown = contributes["markdownViewer"] as? [String: Any] {
                return markdown
            }
        }
        if let viewers = manifest["viewers"] as? [String: Any],
           let markdown = viewers["markdown"] as? [String: Any] {
            return markdown
        }
        return nil
    }

    private static func resolvedAssetURL(
        _ rawPath: String,
        relativeTo root: URL,
        allowedExtensions: Set<String>
    ) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\0"),
              URLComponents(string: path)?.scheme == nil else {
            return nil
        }

        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let candidate = root.appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        guard isDescendant(candidate, of: rootURL) else { return nil }

        let ext = candidate.pathExtension.lowercased()
        guard allowedExtensions.contains(ext),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    private static func readTextAsset(_ url: URL, maximumBytes: Int) -> String? {
        guard maximumBytes > 0,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url),
              data.count <= maximumBytes else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func sanitizedStyleSource(_ source: String) -> String? {
        let lowercased = source.lowercased()
        guard !lowercased.contains("</style"),
              lowercased.range(of: #"@import\b"#, options: .regularExpression) == nil,
              lowercased.range(of: #"url\s*\("#, options: .regularExpression) == nil else {
            return nil
        }
        return source
    }

    private static func styleHTML(extensionID: String, assetPath: String, source: String) -> String {
        """
        <style data-cmux-extension-viewer="\(htmlAttributeEscaped(extensionID))" data-cmux-extension-asset="\(htmlAttributeEscaped(assetPath))">
        /* cmux extension \(cssCommentEscaped(extensionID)):\(cssCommentEscaped(assetPath)) */
        \(source)
        </style>
        """
    }

    private static func scriptHTML(extensionID: String, assetPath: String, source: String) -> String {
        let idLiteral = javaScriptStringLiteral(extensionID)
        let assetLiteral = javaScriptStringLiteral(assetPath)
        let safeSource = source.replacingOccurrences(
            of: "</script",
            with: "<\\/script",
            options: [.caseInsensitive]
        )
        return """
        <script data-cmux-extension-viewer="\(htmlAttributeEscaped(extensionID))" data-cmux-extension-asset="\(htmlAttributeEscaped(assetPath))">
        ;try {
        (function(cmuxMarkdownViewer) {
        \(safeSource)
        })(window.cmuxMarkdownViewer);
        } catch (error) {
          console.error('[cmux] markdown viewer extension failed', \(idLiteral), \(assetLiteral), error);
        }
        //# sourceURL=cmux-extension-\(sourceURLComponent(extensionID))-\(sourceURLComponent(assetPath)).js
        </script>
        """
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = object[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func stringValues(in object: [String: Any], keys: [String]) -> [String] {
        var values: [String] = []
        for key in keys {
            if let raw = object[key] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
            }
            if let rawValues = object[key] as? [Any] {
                values.append(contentsOf: rawValues.compactMap { value in
                    guard let string = value as? String else { return nil }
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                })
            }
        }

        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = String(value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
        return sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    }

    private static func htmlAttributeEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func cssCommentEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "*/", with: "* /")
    }

    private static func sourceURLComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let sanitized = String(value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        })
        return sanitized.isEmpty ? "extension" : sanitized
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }
}
