/// Resolves file-tree selections into stable continuous-diff section identifiers.
public struct DiffTreeScrollTargetResolver: Sendable {
    /// Creates a target resolver.
    public init() {}

    /// Resolves a selected file path when it exists in the current patch set.
    /// - Parameters:
    ///   - path: The repository-relative path selected in the tree.
    ///   - files: The current diff file snapshots.
    /// - Returns: The stable section identifier, or `nil` for stale/non-file selections.
    public func target(path: String, files: [DiffFileSnapshot]) -> String? {
        files.contains(where: { $0.summary.path == path }) ? sectionID(path: path) : nil
    }

    /// Produces the stable section identifier for a repository-relative path.
    /// - Parameter path: The file path represented by the section.
    /// - Returns: An identifier shared by tree navigation and the continuous list.
    public func sectionID(path: String) -> String {
        "diff-file:\(path)"
    }
}
