import Foundation

/// Captures the main-actor file-node graph into a Sendable filename index in bounded chunks.
@MainActor
final class FileExplorerTreeFilterSnapshotBuilder {
    private static let asynchronousChunkSize = 256

    private var nodeGroups: [[FileExplorerNode]]
    private var groupIndexes: [Int]
    private var parentPaths: [String?]
    private var namesByPath: [String: String] = [:]
    private var parentByPath: [String: String] = [:]
    private var rootPaths: [String] = []
    private var childrenByPath: [String: [String]] = [:]
    private var nodesByPath: [String: FileExplorerNode] = [:]

    init(nodes: [FileExplorerNode]) {
        nodeGroups = [nodes]
        groupIndexes = [0]
        parentPaths = [nil]
    }

    func buildSynchronously(
        upTo nodeLimit: Int
    ) -> (snapshot: FileExplorerTreeFilterSnapshot, nodesByPath: [String: FileExplorerNode])? {
        var processedNodeCount = 0
        while processedNodeCount < nodeLimit, processNextNode() {
            processedNodeCount += 1
        }
        return nodeGroups.isEmpty ? capturedIndex() : nil
    }

    func build() async throws
        -> (snapshot: FileExplorerTreeFilterSnapshot, nodesByPath: [String: FileExplorerNode])
    {
        while !nodeGroups.isEmpty {
            try Task.checkCancellation()
            for _ in 0..<Self.asynchronousChunkSize {
                guard processNextNode() else { break }
            }
            if !nodeGroups.isEmpty {
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        return capturedIndex()
    }

    private func processNextNode() -> Bool {
        while let nodes = nodeGroups.last,
              let index = groupIndexes.last,
              let parentPath = parentPaths.last {
            guard index < nodes.count else {
                nodeGroups.removeLast()
                groupIndexes.removeLast()
                parentPaths.removeLast()
                continue
            }

            groupIndexes[groupIndexes.count - 1] = index + 1
            let node = nodes[index]
            nodesByPath[node.path] = node
            namesByPath[node.path] = node.name
            if node.isDirectory {
                childrenByPath[node.path] = []
            }
            if let parentPath {
                parentByPath[node.path] = parentPath
                childrenByPath[parentPath, default: []].append(node.path)
            } else {
                rootPaths.append(node.path)
            }

            if let children = node.children, !children.isEmpty {
                nodeGroups.append(children)
                groupIndexes.append(0)
                parentPaths.append(node.path)
            }
            return true
        }
        return false
    }

    private func capturedIndex()
        -> (snapshot: FileExplorerTreeFilterSnapshot, nodesByPath: [String: FileExplorerNode])
    {
        let snapshot = FileExplorerTreeFilterSnapshot(
            namesByPath: namesByPath,
            parentByPath: parentByPath,
            rootPaths: rootPaths,
            childrenByPath: childrenByPath
        )
        return (snapshot, nodesByPath)
    }
}
