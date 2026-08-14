import Foundation

/// Bounds native file-preview highlighting and maps file extensions to highlight.js languages.
struct FilePreviewSyntaxHighlightPolicy: Sendable {
    static let maximumHighlightBytes = 1_500_000
    static let maximumAutomaticDetectionBytes = 256_000

    private static let languagesByExtension: [String: String] = [
        "bash": "bash", "c": "c", "cc": "cpp", "cjs": "javascript",
        "clj": "clojure", "cljs": "clojure", "cpp": "cpp", "cs": "csharp",
        "css": "css", "cxx": "cpp", "dart": "dart", "ex": "elixir",
        "exs": "elixir", "fs": "fsharp", "fsx": "fsharp", "go": "go",
        "gradle": "gradle", "groovy": "groovy", "h": "c", "hh": "cpp",
        "hpp": "cpp", "htm": "html", "html": "html", "java": "java",
        "js": "javascript", "json": "json", "jsx": "javascript", "kt": "kotlin",
        "kts": "kotlin", "less": "less", "lua": "lua", "m": "objectivec",
        "markdown": "markdown", "md": "markdown", "mjs": "javascript",
        "mm": "objectivec", "php": "php", "pl": "perl", "pm": "perl",
        "py": "python", "r": "r", "rb": "ruby", "rs": "rust", "sass": "scss",
        "scala": "scala", "scss": "scss", "sh": "bash", "sql": "sql",
        "swift": "swift", "ts": "typescript", "tsx": "typescript", "xml": "xml",
        "yaml": "yaml", "yml": "yaml", "zsh": "bash",
    ]

    func decision(path: String, byteCount: Int) -> FilePreviewSyntaxHighlightDecision {
        guard byteCount <= Self.maximumHighlightBytes else { return .skip }
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        if let language = Self.languagesByExtension[pathExtension] {
            return .highlight(language: language)
        }
        guard byteCount < Self.maximumAutomaticDetectionBytes else { return .skip }
        return .highlight(language: nil)
    }
}
