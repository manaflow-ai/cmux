import Foundation

/// Selects syntax highlighting without spending unbounded work on large artifacts.
struct ChatArtifactSyntaxHighlightPolicy: Sendable {
    static let maxHighlightBytes: Int64 = 1_500_000
    static let maxAutomaticDetectionBytes: Int64 = 256_000

    private static let languagesByExtension: [String: String] = [
        "bash": "bash",
        "c": "c",
        "cc": "cpp",
        "cjs": "javascript",
        "clj": "clojure",
        "cljs": "clojure",
        "cpp": "cpp",
        "cs": "csharp",
        "css": "css",
        "cxx": "cpp",
        "dart": "dart",
        "ex": "elixir",
        "exs": "elixir",
        "fs": "fsharp",
        "fsx": "fsharp",
        "go": "go",
        "gradle": "gradle",
        "groovy": "groovy",
        "h": "c",
        "hh": "cpp",
        "hpp": "cpp",
        "htm": "html",
        "html": "html",
        "java": "java",
        "js": "javascript",
        "json": "json",
        "jsx": "javascript",
        "kt": "kotlin",
        "kts": "kotlin",
        "less": "less",
        "lua": "lua",
        "m": "objectivec",
        "markdown": "markdown",
        "md": "markdown",
        "mjs": "javascript",
        "mm": "objectivec",
        "php": "php",
        "pl": "perl",
        "pm": "perl",
        "py": "python",
        "r": "r",
        "rb": "ruby",
        "rs": "rust",
        "sass": "scss",
        "scala": "scala",
        "scss": "scss",
        "sh": "bash",
        "sql": "sql",
        "swift": "swift",
        "ts": "typescript",
        "tsx": "typescript",
        "xml": "xml",
        "yaml": "yaml",
        "yml": "yaml",
        "zsh": "bash",
    ]

    /// Returns the bounded highlighting decision for a path and its real byte size.
    func decision(path: String, byteCount: Int64) -> ChatArtifactHighlightDecision {
        guard byteCount <= Self.maxHighlightBytes else {
            return .skippedForSize
        }

        if let language = inferredLanguage(path: path) {
            return .highlight(language: language)
        }
        if byteCount < Self.maxAutomaticDetectionBytes {
            return .highlight(language: nil)
        }
        return .skippedNoLanguage
    }

    /// Returns a highlight.js language inferred strictly from the path extension.
    func inferredLanguage(path: String) -> String? {
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return Self.languagesByExtension[pathExtension]
    }
}
