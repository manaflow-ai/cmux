import Foundation

/// A normalized full-text search request and its ripgrep arguments.
struct FileSearchRequest: Equatable, Sendable {
    let query: String
    let rootPath: String
    let isLocal: Bool
    let contentRevision: Int

    init(
        query: String,
        rootPath: String,
        isLocal: Bool,
        contentRevision: Int
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rootPath = rootPath
        self.isLocal = isLocal
        self.contentRevision = contentRevision
    }

    var ripgrepArguments: [String] {
        var arguments = [
            "--json",
            "--line-number",
            "--column",
            "--smart-case",
            "--fixed-strings",
            "--max-columns", "300",
            "--max-columns-preview",
            "--color", "never",
            "--hidden",
        ]
        for pattern in Self.defaultExcludedGlobs {
            arguments += ["--glob", pattern]
        }
        arguments += ["--", query, rootPath]
        return arguments
    }

    private static let defaultExcludedGlobs = [
        "!.git/**",
        "!**/.git/**",
        "!node_modules/**",
        "!**/node_modules/**",
        "!dist/**",
        "!**/dist/**",
        "!build/**",
        "!**/build/**",
        "!DerivedData/**",
        "!**/DerivedData/**",
    ]
}
