import Foundation

/// Maps repository filenames to Highlight.js language identifiers.
public struct DiffLanguageMapper: Sendable {
    /// Creates a filename mapper.
    public init() {}

    /// Returns a Highlight.js identifier for a path when one is known.
    /// - Parameter filename: A filename or repository-relative path.
    /// - Returns: A language identifier, or `nil` for plain text.
    public func language(for filename: String) -> String? {
        let basename = URL(fileURLWithPath: filename).lastPathComponent.lowercased()
        if let special = specialFilenames[basename] { return special }
        let pathExtension = URL(fileURLWithPath: basename).pathExtension.lowercased()
        return extensions[pathExtension]
    }

    private var specialFilenames: [String: String] {
        [
            "dockerfile": "dockerfile",
            "makefile": "makefile",
            "package.swift": "swift",
            "package.resolved": "json",
        ]
    }

    private var extensions: [String: String] {
        [
            "c": "c", "cc": "cpp", "cpp": "cpp", "css": "css",
            "go": "go", "h": "c", "hpp": "cpp", "html": "xml",
            "java": "java", "js": "javascript", "json": "json",
            "jsx": "javascript", "kt": "kotlin", "kts": "kotlin",
            "m": "objectivec", "md": "markdown", "mm": "objectivec",
            "php": "php", "pl": "perl", "py": "python", "rb": "ruby",
            "rs": "rust", "sh": "bash", "sql": "sql", "swift": "swift",
            "toml": "ini", "ts": "typescript", "tsx": "typescript",
            "xml": "xml", "yaml": "yaml", "yml": "yaml", "zig": "zig",
        ]
    }
}
