import Foundation
import zlib

/// Loads the bundled markdown web renderer assets from Resources/markdown-viewer.
/// The heavy diagram libraries are still read lazily so ordinary markdown files
/// do not pay the Mermaid/Vega I/O cost.
@MainActor
final class MarkdownViewerAssets {
    typealias AssetLoader = (_ name: String, _ ext: String) -> String?

    static let shared = MarkdownViewerAssets { name, ext in
        loadAsset(name: name, ext: ext)
    }

    private let assetLoader: AssetLoader
    private let markedJS: String
    private let highlightJS: String
    private let highlightLightCSS: String
    private let highlightDarkCSS: String
    private let githubMarkdownCSS: String
    private let viewerNavigationJS: String
    private let shellTemplate: String
    private let localizedStringsJSON: String
    private let hasMissingRequiredAssets: Bool

    private var lazyCache: [String: String] = [:]
    private var unavailableLazyAssets: Set<String> = []

    init(assetLoader: @escaping AssetLoader) {
        self.assetLoader = assetLoader
        var hasMissingRequiredAssets = false
        func requiredAsset(name: String, ext: String) -> String {
            guard let source = assetLoader(name, ext), !source.isEmpty else {
                hasMissingRequiredAssets = true
                return ""
            }
            return source
        }

        markedJS = requiredAsset(name: "marked.min", ext: "js")
        highlightJS = requiredAsset(name: "highlight.min", ext: "js")
        highlightLightCSS = requiredAsset(name: "highlight-github", ext: "css")
        highlightDarkCSS = requiredAsset(name: "highlight-github-dark", ext: "css")
        githubMarkdownCSS = requiredAsset(name: "github-markdown", ext: "css")
        viewerNavigationJS = requiredAsset(name: "viewer-navigation", ext: "js")
        shellTemplate = requiredAsset(name: "shell", ext: "html")
        localizedStringsJSON = MarkdownViewerAssets.localizedStringsJSON()
        self.hasMissingRequiredAssets = hasMissingRequiredAssets
    }

    func shellHTML(isDark: Bool) -> String {
        _ = isDark
        guard !hasMissingRequiredAssets else {
            return Self.unavailableAssetsHTML()
        }
        return shellTemplate
            .replacingOccurrences(of: "{{githubMarkdownCSS}}", with: githubMarkdownCSS)
            .replacingOccurrences(of: "{{highlightLightCSS}}", with: highlightLightCSS)
            .replacingOccurrences(of: "{{highlightDarkCSS}}", with: highlightDarkCSS)
            .replacingOccurrences(of: "{{markedJS}}", with: markedJS)
            .replacingOccurrences(of: "{{highlightJS}}", with: highlightJS)
            .replacingOccurrences(of: "{{viewerNavigationJS}}", with: viewerNavigationJS)
            .replacingOccurrences(of: "{{localizedStringsJSON}}", with: localizedStringsJSON)
    }

    /// Load and cache a bundled JS asset on demand.
    func lazyAsset(name: String, ext: String) -> String? {
        let key = "\(name).\(ext)"
        if let cached = lazyCache[key] {
            return cached
        }
        guard !unavailableLazyAssets.contains(key),
              let source = assetLoader(name, ext),
              !source.isEmpty else {
            unavailableLazyAssets.insert(key)
            return nil
        }
        lazyCache[key] = source
        return source
    }

    private static func loadAsset(name: String, ext: String) -> String? {
        let bundle = Bundle.main
        let compressedCandidates: [URL?] = [
            bundle.url(forResource: name, withExtension: "\(ext).deflate", subdirectory: "markdown-viewer"),
            bundle.url(forResource: name, withExtension: "\(ext).deflate")
        ]
        for case let url? in compressedCandidates {
            if let source = loadDeflatedTextAsset(url: url), !source.isEmpty {
                return source
            }
            NSLog("MarkdownViewerAssets: invalid compressed asset \(url.lastPathComponent)")
        }

        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: ext, subdirectory: "markdown-viewer"),
            bundle.url(forResource: name, withExtension: ext)
        ]
        for case let url? in candidates {
            if let source = try? String(contentsOf: url, encoding: .utf8), !source.isEmpty {
                return source
            }
        }
        NSLog("MarkdownViewerAssets: missing bundled asset \(name).\(ext)")
        return nil
    }

    private static func unavailableAssetsHTML() -> String {
        let title = htmlEscaped(
            String(
                localized: "markdown.web.assetsUnavailableTitle",
                defaultValue: "Markdown preview unavailable"
            )
        )
        let message = htmlEscaped(
            String(
                localized: "markdown.web.assetsUnavailableMessage",
                defaultValue: "Restart cmux. If this keeps happening, reinstall the app."
            )
        )
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body {
          margin: 0;
          padding: 32px;
          background: transparent;
          color: CanvasText;
          font: 14px/1.5 -apple-system, BlinkMacSystemFont, sans-serif;
        }
        main { max-width: 560px; margin: 0 auto; }
        h1 { margin: 0 0 8px; font-size: 18px; }
        p { margin: 0; color: GrayText; }
        </style>
        </head>
        <body><main data-cmux-markdown-assets-unavailable>
        <h1>\(title)</h1><p>\(message)</p>
        </main></body>
        </html>
        """
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
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
              let decompressed = inflateZlib(compressed) else {
            return nil
        }
        return String(data: decompressed, encoding: .utf8)
    }

    private static func inflateZlib(_ data: Data) -> Data? {
        guard !data.isEmpty else {
            return Data()
        }

        var stream = z_stream()
        let initResult = inflateInit_(
            &stream,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        return data.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return nil
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            var output = Data()
            let chunkSize = 64 * 1024
            var chunk = [UInt8](repeating: 0, count: chunkSize)

            while true {
                let result = chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(chunk, count: produced)
                }

                if result == Z_STREAM_END {
                    return output
                }
                if result != Z_OK {
                    return nil
                }
                if stream.avail_in == 0 && produced == 0 {
                    return nil
                }
            }
        }
    }
}
