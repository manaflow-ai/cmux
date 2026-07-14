import Foundation

/// Filters an immutable index of already-loaded nodes without loading directories.
struct FileExplorerTreeFilter {
    private(set) var query = ""
    private(set) var snapshot = FileExplorerTreeFilterSnapshot.empty
    private var nodesByPath: [String: FileExplorerNode] = [:]
    private var visiblePaths: Set<String> = []
    private(set) var needsFiltering = false

    var isActive: Bool { !query.isEmpty }

    @discardableResult
    mutating func setQuery(_ rawQuery: String) -> Bool {
        let nextQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextQuery != query else { return false }
        query = nextQuery
        needsFiltering = !nextQuery.isEmpty
        if nextQuery.isEmpty {
            visiblePaths.removeAll(keepingCapacity: true)
        }
        return true
    }

    @MainActor
    mutating func rebuildIndex(nodes: [FileExplorerNode]) {
        let captured = FileExplorerTreeFilterSnapshot.capture(nodes: nodes)
        snapshot = captured.snapshot
        nodesByPath = captured.nodesByPath
        needsFiltering = isActive
    }

    @discardableResult
    mutating func apply(_ result: FileExplorerTreeFilterResult) -> Bool {
        guard result.query == query else { return false }
        visiblePaths = result.visiblePaths
        needsFiltering = false
        return true
    }

    func visibleRootNodes(in nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        guard isActive else { return nodes }
        return snapshot.rootPaths.compactMap { path in
            guard visiblePaths.contains(path) else { return nil }
            return nodesByPath[path]
        }
    }

    func visibleChildren(of node: FileExplorerNode) -> [FileExplorerNode] {
        guard isActive else { return node.sortedChildren ?? [] }
        return (snapshot.childrenByPath[node.path] ?? []).compactMap { path in
            guard visiblePaths.contains(path) else { return nil }
            return nodesByPath[path]
        }
    }

    func hasVisibleChildren(_ node: FileExplorerNode) -> Bool {
        !visibleChildren(of: node).isEmpty
    }
}
