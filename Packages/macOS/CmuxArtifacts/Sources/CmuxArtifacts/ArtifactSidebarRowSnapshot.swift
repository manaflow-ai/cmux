public import Foundation

/// Immutable row value rendered below the sidebar's lazy-list boundary.
public struct ArtifactSidebarRowSnapshot: Identifiable, Equatable, Sendable {
    /// Stable row identity, equal to the artifact-relative path.
    public let id: String
    /// Basename shown as the primary row label.
    public let name: String
    /// Path relative to `.cmux/artifacts`.
    public let relativePath: String
    /// Absolute local file URL used by preview and drag actions.
    public let fileURL: URL
    /// Tree indentation depth.
    public let depth: Int
    /// Whether the row represents a directory.
    public let isDirectory: Bool
    /// Whether a directory is currently expanded.
    public let isExpanded: Bool
    /// Preview classification for file rows.
    public let fileKind: ArtifactFileKind?
    /// Whether a content-search match contributed to this result.
    public let matchedContent: Bool
    /// Bounded content-search excerpt, when available.
    public let snippet: String?

    /// Creates an immutable sidebar row.
    ///
    /// - Parameters:
    ///   - id: Stable row identity.
    ///   - name: Basename shown in the row.
    ///   - relativePath: Path relative to the artifact root.
    ///   - fileURL: Absolute local file URL.
    ///   - depth: Tree indentation depth.
    ///   - isDirectory: Whether the row is a directory.
    ///   - isExpanded: Whether the directory is expanded.
    ///   - fileKind: Preview classification for a file.
    ///   - matchedContent: Whether file contents matched a search.
    ///   - snippet: Bounded single-line content excerpt.
    public init(
        id: String,
        name: String,
        relativePath: String,
        fileURL: URL,
        depth: Int,
        isDirectory: Bool,
        isExpanded: Bool,
        fileKind: ArtifactFileKind?,
        matchedContent: Bool = false,
        snippet: String? = nil
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.depth = depth
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.fileKind = fileKind
        self.matchedContent = matchedContent
        self.snippet = snippet
    }
}
