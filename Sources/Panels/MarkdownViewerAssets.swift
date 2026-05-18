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

    private var lazyCache: [String: String] = [:]

    private init() {
        markedJS = MarkdownViewerAssets.loadAsset(name: "marked.min", ext: "js")
        highlightJS = MarkdownViewerAssets.loadAsset(name: "highlight.min", ext: "js")
        highlightLightCSS = MarkdownViewerAssets.loadAsset(name: "highlight-github", ext: "css")
        highlightDarkCSS = MarkdownViewerAssets.loadAsset(name: "highlight-github-dark", ext: "css")
        githubMarkdownCSS = MarkdownViewerAssets.loadAsset(name: "github-markdown", ext: "css")
        shellTemplate = MarkdownViewerAssets.loadAsset(name: "shell", ext: "html")
    }

    func shellHTML(isDark: Bool) -> String {
        _ = isDark
        return shellTemplate
            .replacingOccurrences(of: "{{githubMarkdownCSS}}", with: githubMarkdownCSS)
            .replacingOccurrences(of: "{{highlightLightCSS}}", with: highlightLightCSS)
            .replacingOccurrences(of: "{{highlightDarkCSS}}", with: highlightDarkCSS)
            .replacingOccurrences(of: "{{markedJS}}", with: markedJS)
            .replacingOccurrences(of: "{{highlightJS}}", with: highlightJS)
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

    private static func loadDeflatedTextAsset(url: URL) -> String? {
        guard let compressed = try? Data(contentsOf: url),
              let decompressed = try? (compressed as NSData).decompressed(using: .zlib) as Data else {
            return nil
        }
        return String(data: decompressed, encoding: .utf8)
    }
}
