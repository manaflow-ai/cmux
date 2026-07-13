import Foundation
import zlib

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
            .replacingOccurrences(of: "{{markedJS}}", with: markedJS)
            .replacingOccurrences(of: "{{highlightJS}}", with: highlightJS)
            .replacingOccurrences(of: "{{localizedStringsJSON}}", with: localizedStringsJSON)
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
