import Foundation

/// Filters the already-loaded file tree without triggering recursive directory loads.
struct FileExplorerTreeFilter {
    private(set) var query = ""
    private var filteredRootNodes: [FileExplorerNode] = []
    private var filteredChildrenByPath: [String: [FileExplorerNode]] = [:]

    var isActive: Bool { !query.isEmpty }

    @discardableResult
    mutating func update(query rawQuery: String, nodes: [FileExplorerNode]) -> Bool {
        let nextQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nextQuery != query else { return false }
        query = nextQuery
        rebuild(nodes: nodes)
        return true
    }

    mutating func rebuild(nodes: [FileExplorerNode]) {
        filteredRootNodes.removeAll(keepingCapacity: true)
        filteredChildrenByPath.removeAll(keepingCapacity: true)
        guard isActive else { return }
        for node in nodes {
            if collectMatches(in: node) { filteredRootNodes.append(node) }
        }
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

    private mutating func collectMatches(in node: FileExplorerNode) -> Bool {
        var matches = node.name.localizedCaseInsensitiveContains(query)
        var visibleChildren: [FileExplorerNode] = []
        for child in node.sortedChildren ?? [] {
            if collectMatches(in: child) {
                matches = true
                visibleChildren.append(child)
            }
        }
        filteredChildrenByPath[node.path] = visibleChildren
        return matches
    }
}
