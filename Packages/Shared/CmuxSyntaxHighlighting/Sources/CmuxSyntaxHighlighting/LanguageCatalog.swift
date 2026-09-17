import Foundation

/// Maps on-disk file extensions to highlight.js language identifiers.
///
/// Unknown extensions return `nil` so callers can skip token coloring
/// without auto-detecting on large buffers.
public struct LanguageCatalog: Sendable {
    /// Creates a catalog with the built-in extension table.
    public init() {}

    /// Returns the highlight.js language id for `ext`, or `nil` if unknown.
    ///
    /// Comparison is case-insensitive and ignores a leading dot.
    public func language(forExtension ext: String) -> String? {
        var key = ext.lowercased()
        if key.hasPrefix(".") {
            key.removeFirst()
        }
        return Self.languageByExtension[key]
    }

    /// Returns the highlight.js language id inferred from `url.pathExtension`.
    public func language(for url: URL) -> String? {
        language(forExtension: url.pathExtension)
    }

    private static let languageByExtension: [String: String] = [
        "swift": "swift",
        "ts": "typescript",
        "tsx": "typescript",
        "cts": "typescript",
        "mts": "typescript",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "py": "python",
        "json": "json",
        "jsonc": "json",
        "md": "markdown",
        "markdown": "markdown",
        "mdx": "markdown",
        "go": "go",
        "rs": "rust",
        "rb": "ruby",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "cs": "csharp",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "mm": "objectivec",
        "m": "objectivec",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "fish": "bash",
        "yml": "yaml",
        "yaml": "yaml",
        "toml": "ini",
        "ini": "ini",
        "cfg": "ini",
        "conf": "ini",
        "css": "css",
        "html": "xml",
        "htm": "xml",
        "xml": "xml",
        "sql": "sql",
    ]
}
