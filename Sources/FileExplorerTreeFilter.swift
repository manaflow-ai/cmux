import Foundation

/// Filters the already-loaded file tree without triggering recursive directory loads.
struct FileExplorerTreeFilter: Equatable {
    private(set) var query = ""
    private var matchingPaths = Set<String>()

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
        matchingPaths.removeAll(keepingCapacity: true)
        guard isActive else { return }
        for node in nodes {
            _ = collectMatches(in: node)
        }
    }

    func visibleNodes(in nodes: [FileExplorerNode]) -> [FileExplorerNode] {
        guard isActive else { return nodes }
        return nodes.filter { matchingPaths.contains($0.path) }
    }

    func hasVisibleChildren(_ node: FileExplorerNode) -> Bool {
        !visibleNodes(in: node.sortedChildren ?? []).isEmpty
    }

    private mutating func collectMatches(in node: FileExplorerNode) -> Bool {
        var matches = node.name.localizedCaseInsensitiveContains(query)
        for child in node.sortedChildren ?? [] where collectMatches(in: child) {
            matches = true
        }
        if matches { matchingPaths.insert(node.path) }
        return matches
    }
}
