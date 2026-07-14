import Foundation

/// Immutable, already-loaded filename index used by cancellable off-main filtering.
nonisolated struct FileExplorerTreeFilterSnapshot: Sendable {
    static let synchronousNodeLimit = 2_048

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

    @MainActor
    static func capture(
        nodes: [FileExplorerNode]
    ) -> (snapshot: FileExplorerTreeFilterSnapshot, nodesByPath: [String: FileExplorerNode]) {
        var namesByPath: [String: String] = [:]
        var parentByPath: [String: String] = [:]
        var childrenByPath: [String: [String]] = [:]
        var nodesByPath: [String: FileExplorerNode] = [:]
        Self.append(
            nodes,
            parentPath: nil,
            namesByPath: &namesByPath,
            parentByPath: &parentByPath,
            childrenByPath: &childrenByPath,
            nodesByPath: &nodesByPath
        )
        let snapshot = FileExplorerTreeFilterSnapshot(
            namesByPath: namesByPath,
            parentByPath: parentByPath,
            rootPaths: nodes.map(\.path),
            childrenByPath: childrenByPath
        )
        return (snapshot, nodesByPath)
    }

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

    private init(
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
        for (index, entry) in namesByPath.enumerated() {
            if checksCancellation, index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            guard entry.value.localizedStandardContains(query) else { continue }
            var path: String? = entry.key
            while let currentPath = path {
                if checksCancellation {
                    try Task.checkCancellation()
                }
                guard visiblePaths.insert(currentPath).inserted else { break }
                path = parentByPath[currentPath]
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

    @MainActor
    private static func append(
        _ nodes: [FileExplorerNode],
        parentPath: String?,
        namesByPath: inout [String: String],
        parentByPath: inout [String: String],
        childrenByPath: inout [String: [String]],
        nodesByPath: inout [String: FileExplorerNode]
    ) {
        for node in nodes {
            nodesByPath[node.path] = node
            namesByPath[node.path] = node.name
            if let parentPath {
                parentByPath[node.path] = parentPath
            }
            // FileExplorerStore keeps loaded siblings sorted; preserving that
            // order avoids recursive comparison work on the main actor.
            let children = node.children ?? []
            childrenByPath[node.path] = children.map(\.path)
            append(
                children,
                parentPath: node.path,
                namesByPath: &namesByPath,
                parentByPath: &parentByPath,
                childrenByPath: &childrenByPath,
                nodesByPath: &nodesByPath
            )
        }
    }
}
