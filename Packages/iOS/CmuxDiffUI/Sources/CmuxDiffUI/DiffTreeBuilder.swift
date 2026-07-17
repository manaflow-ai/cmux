/// Builds a collapsed directory tree from flat changed-file paths.
public struct DiffTreeBuilder: Sendable {
    /// Creates a tree builder.
    public init() {}

    /// Builds sorted root nodes, collapsing single-child directory chains.
    /// - Parameter files: File snapshots whose paths and statuses populate the tree.
    /// - Returns: Sorted root directory and file nodes.
    public func build(files: [DiffFileSnapshot]) -> [DiffTreeNode] {
        var root = DiffTreeAccumulator()
        for file in files {
            let components = file.summary.path.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty else { continue }
            root.insert(components: components[...], status: file.summary.status)
        }
        return root.children.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { $0.node() }
    }
}
