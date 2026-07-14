import Foundation

/// Filters an immutable index of already-loaded nodes without loading directories.
struct FileExplorerTreeFilter {
    private(set) var query = ""
    private(set) var snapshot = FileExplorerTreeFilterSnapshot.empty
    private var nodesByPath: [String: FileExplorerNode] = [:]
    private var filteredRootNodes: [FileExplorerNode] = []
    private var filteredChildrenByPath: [String: [FileExplorerNode]] = [:]
    private var matchingPaths: Set<String> = []
    private(set) var needsFiltering = false

    var isActive: Bool { !query.isEmpty }

    @discardableResult
    mutating func setQuery(_ rawQuery: String) -> Bool {
        let nextQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextQuery != query else { return false }
        query = nextQuery
        needsFiltering = !nextQuery.isEmpty
        if nextQuery.isEmpty {
            filteredRootNodes.removeAll(keepingCapacity: true)
            filteredChildrenByPath.removeAll(keepingCapacity: true)
            matchingPaths.removeAll(keepingCapacity: true)
        }
        return true
    }

    @MainActor
    mutating func replaceIndex(
        snapshot: FileExplorerTreeFilterSnapshot,
        nodesByPath: [String: FileExplorerNode]
    ) {
        self.snapshot = snapshot
        self.nodesByPath = nodesByPath
        needsFiltering = isActive
    }

    @discardableResult
    mutating func apply(_ result: FileExplorerTreeFilterResult) -> Bool {
        guard result.query == query else { return false }
        filteredRootNodes = result.rootPaths.compactMap { nodesByPath[$0] }
        filteredChildrenByPath.removeAll(keepingCapacity: true)
        for (path, children) in result.childrenByPath {
            filteredChildrenByPath[path] = children.compactMap { nodesByPath[$0] }
        }
        matchingPaths = result.matchingPaths
        needsFiltering = false
        return true
    }

    func visibleRootNodes(in nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        isActive ? filteredRootNodes : nodes
    }

    func visibleChildren(of node: FileExplorerNode) -> [FileExplorerNode] {
        isActive ? filteredChildrenByPath[node.path] ?? [] : node.sortedChildren ?? []
    }

    func hasVisibleChildren(_ node: FileExplorerNode) -> Bool {
        !visibleChildren(of: node).isEmpty
    }

    func isDirectMatch(_ node: FileExplorerNode) -> Bool {
        matchingPaths.contains(node.path)
    }

    mutating func invalidateIndex() {
        snapshot = .empty
        nodesByPath.removeAll()
        filteredRootNodes.removeAll()
        filteredChildrenByPath.removeAll()
        matchingPaths.removeAll()
        needsFiltering = isActive
    }
}
