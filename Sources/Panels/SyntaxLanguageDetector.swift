import CodeEditLanguages
import Foundation

/// Maps file URLs to a `CodeLanguage` for TreeSitter syntax highlighting.
///
/// Returns `nil` for unsupported extensions or files above the size threshold,
/// which routes the caller to the plain-text editor fallback.
enum SyntaxLanguageDetector {
    private static let supportedExtensions: Set<String> = [
        "agda",
        "bash", "sh",
        "c", "h",
        "swift",
        "cc", "cpp", "cxx", "hpp", "hh",
        "cs",
        "css",
        "dart",
        "ex", "exs",
        "go",
        "hs",
        "htm", "html", "shtml",
        "java", "jav",
        "jl",
        "js", "cjs", "mjs",
        "json",
        "jsx",
        "kt", "kts",
        "lua",
        "md", "mkd", "mkdn", "mdwn", "mdown", "markdown",
        "ml", "mli",
        "php",
        "pl", "pm",
        "py",
        "rb",
        "rs",
        "scala", "sc",
        "sql",
        "toml",
        "ts", "cts", "mts",
        "tsx",
        "v",
        "yaml", "yml",
        "zig",
    ]

    // Files larger than this threshold fall back to PlainFilePreviewEditor
    // to avoid TreeSitter latency spikes on large logs, generated code, etc.
    private static let maxHighlightBytes = 500_000

    static func language(for url: URL) -> CodeLanguage? {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent
        guard supportedExtensions.contains(ext) || filename == "Dockerfile" else { return nil }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size > maxHighlightBytes {
            return nil
        }
        return CodeLanguage.detectLanguageFrom(url: url)
    }
}
