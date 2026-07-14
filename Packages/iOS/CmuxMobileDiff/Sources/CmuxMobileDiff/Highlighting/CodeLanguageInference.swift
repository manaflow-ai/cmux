internal import Foundation

/// Infers Highlight.js language identifiers from common filename extensions.
struct CodeLanguageInference: Sendable {
    private let languages: [String: String]

    /// Creates an inference map for common source and configuration formats.
    init() {
        languages = [
            "c": "c", "cc": "cpp", "cpp": "cpp", "cs": "csharp", "css": "css",
            "go": "go", "h": "c", "hpp": "cpp", "html": "html", "java": "java",
            "js": "javascript", "json": "json", "jsx": "javascript", "kt": "kotlin",
            "kts": "kotlin", "md": "markdown", "m": "objectivec", "mm": "objectivec",
            "php": "php", "pl": "perl", "py": "python", "rb": "ruby", "rs": "rust",
            "sh": "bash", "sql": "sql", "swift": "swift", "toml": "ini", "ts": "typescript",
            "tsx": "typescript", "xml": "xml", "yaml": "yaml", "yml": "yaml", "zig": "zig",
        ]
    }

    /// Returns a language identifier, or `nil` for plain text and unknown extensions.
    /// - Parameter filename: Repository-relative filename.
    /// - Returns: Highlight.js language identifier when known.
    func language(for filename: String) -> String? {
        let leaf = (filename as NSString).lastPathComponent.lowercased()
        if leaf == "dockerfile" { return "dockerfile" }
        if leaf == "makefile" { return "makefile" }
        guard let extensionStart = leaf.lastIndex(of: ".") else { return nil }
        return languages[String(leaf[leaf.index(after: extensionStart)...])]
    }
}
