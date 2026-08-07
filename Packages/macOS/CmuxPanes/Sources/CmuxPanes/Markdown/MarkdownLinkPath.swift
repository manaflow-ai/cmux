import Foundation

/// A link destination classified for Markdown-file routing.
public struct MarkdownLinkPath: Equatable, Sendable {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mkd", "mdx"]

    /// The destination exactly as supplied by the caller.
    public let rawValue: String

    /// Creates a Markdown link-path value.
    ///
    /// - Parameter rawValue: The authored or resolved link destination.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Whether the destination is a path-like Markdown file rather than a
    /// non-file URL.
    public var isMarkdownFile: Bool {
        let trimmed = pathWithoutQueryOrFragment
        guard !trimmed.isEmpty else { return false }
        // Keep this intentionally path-like: code spans such as `foo.md`,
        // `docs/foo.md`, `../foo.md`, or `/tmp/foo.md` qualify. URLs do not.
        if let url = URL(string: trimmed), url.scheme != nil, url.scheme != "file" {
            return false
        }
        let pathExtension = (trimmed as NSString).pathExtension.lowercased()
        return Self.markdownExtensions.contains(pathExtension)
    }

    var pathWithoutQueryOrFragment: String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        if let question = value.firstIndex(of: "?") {
            value = String(value[..<question])
        }
        return value.removingPercentEncoding ?? value
    }
}
