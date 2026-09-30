import Foundation

/// Everything the user controls in a project-wide search: the pattern and the
/// VS Code style toggles and glob fields.
public struct FileSearchQuery: Hashable, Sendable, Codable {
    /// The text or regular expression to find.
    public var pattern: String
    /// Match Case. When off, the search is case-insensitive.
    public var isCaseSensitive: Bool
    /// Match Whole Word.
    public var matchesWholeWord: Bool
    /// Use Regular Expression. When off, the pattern is a literal string.
    public var isRegex: Bool
    /// Comma-separated globs a file must match ("files to include").
    public var includePatterns: String
    /// Comma-separated globs that remove files ("files to exclude").
    public var excludePatterns: String
    /// Use Exclude Settings and Ignore Files: honor `.gitignore`/`.ignore`
    /// and skip the built-in generated directories.
    public var usesIgnoreFiles: Bool

    public init(
        pattern: String = "",
        isCaseSensitive: Bool = false,
        matchesWholeWord: Bool = false,
        isRegex: Bool = false,
        includePatterns: String = "",
        excludePatterns: String = "",
        usesIgnoreFiles: Bool = true
    ) {
        self.pattern = pattern
        self.isCaseSensitive = isCaseSensitive
        self.matchesWholeWord = matchesWholeWord
        self.isRegex = isRegex
        self.includePatterns = includePatterns
        self.excludePatterns = excludePatterns
        self.usesIgnoreFiles = usesIgnoreFiles
    }

    /// True when there is nothing to search for. Whitespace is a valid
    /// literal pattern, so only the empty string counts.
    public var isEmpty: Bool { pattern.isEmpty }

    /// A syntax problem in a regular-expression pattern, found before ripgrep
    /// runs so the field can show it inline while the user types. ripgrep's own
    /// parser remains authoritative; its error is reported as well.
    public var regexSyntaxError: FileSearchRegexSyntaxError? {
        guard isRegex, !pattern.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return FileSearchRegexSyntaxError(detail: nil)
        }
    }
}

/// An invalid regular expression. `detail` carries ripgrep's diagnostic
/// when it rejected the pattern; the local precheck has none.
public struct FileSearchRegexSyntaxError: Hashable, Sendable {
    public let detail: String?

    public init(detail: String?) {
        self.detail = detail
    }
}
