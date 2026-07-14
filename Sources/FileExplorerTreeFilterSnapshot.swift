import Foundation

/// Immutable, already-loaded filename index used by cancellable off-main filtering.
nonisolated struct FileExplorerTreeFilterSnapshot: Sendable {
    static let synchronousNodeLimit = 2_048
    /// Bounds automatic outline expansion work for broad filename queries.
    static let maximumVisibleNodeCount = 512

    let namesByPath: [String: String]
    let parentByPath: [String: String]
    let rootPaths: [String]
    let childrenByPath: [String: [String]]

    static let empty = FileExplorerTreeFilterSnapshot(
        namesByPath: [:],
        parentByPath: [:],
        rootPaths: [],
        childrenByPath: [:]
    )

    var nodeCount: Int { namesByPath.count }

    func filterSynchronously(query: String) -> FileExplorerTreeFilterResult {
        do {
            return try filteredResult(query: query, checksCancellation: false)
        } catch {
            return .empty(query: query)
        }
    }

    @concurrent
    func filter(query: String) async throws -> FileExplorerTreeFilterResult {
        try filteredResult(query: query, checksCancellation: true)
    }

    init(
        namesByPath: [String: String],
        parentByPath: [String: String],
        rootPaths: [String],
        childrenByPath: [String: [String]]
    ) {
        self.namesByPath = namesByPath
        self.parentByPath = parentByPath
        self.rootPaths = rootPaths
        self.childrenByPath = childrenByPath
    }

    private func filteredResult(
        query: String,
        checksCancellation: Bool
    ) throws -> FileExplorerTreeFilterResult {
        guard !query.isEmpty else { return .empty(query: query) }
        var visiblePaths: Set<String> = []
        var pendingPaths = Array(rootPaths.reversed())
        var visitedNodeCount = 0
        while let path = pendingPaths.popLast() {
            if checksCancellation, visitedNodeCount.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            visitedNodeCount += 1
            if let name = namesByPath[path], name.localizedStandardContains(query) {
                var lineage: [String] = []
                var currentPath: String? = path
                while let candidate = currentPath, !visiblePaths.contains(candidate) {
                    lineage.append(candidate)
                    currentPath = parentByPath[candidate]
                }
                guard visiblePaths.count + lineage.count <= Self.maximumVisibleNodeCount else {
                    break
                }
                visiblePaths.formUnion(lineage)
                if visiblePaths.count == Self.maximumVisibleNodeCount {
                    break
                }
            }
            if let children = childrenByPath[path] {
                pendingPaths.append(contentsOf: children.reversed())
            }
        }
        let filteredRootPaths = rootPaths.filter(visiblePaths.contains)
        var filteredChildrenByPath: [String: [String]] = [:]
        for (index, path) in visiblePaths.enumerated() {
            if checksCancellation, index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard let children = childrenByPath[path] else { continue }
            let visibleChildren = children.filter(visiblePaths.contains)
            if !visibleChildren.isEmpty {
                filteredChildrenByPath[path] = visibleChildren
            }
        }
        return FileExplorerTreeFilterResult(
            query: query,
            rootPaths: filteredRootPaths,
            childrenByPath: filteredChildrenByPath
        )
    }

}
