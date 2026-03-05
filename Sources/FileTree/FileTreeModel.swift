import Foundation
import SwiftUI

@MainActor
final class FileTreeModel: ObservableObject {
    @Published var rootPath: String = ""
    @Published var rootNodes: [FileTreeNode] = []
    @Published var showHiddenFiles: Bool = true

    private var loadGeneration: Int = 0

    func loadDirectory(_ path: String) {
        rootPath = path
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            let nodes = await scanDirectory(path)
            guard generation == self.loadGeneration else { return }
            self.rootNodes = nodes
        }
    }

    func toggleExpand(_ node: FileTreeNode) {
        if node.isDirectory {
            var updated = rootNodes
            let _ = findAndUpdate(in: &updated, id: node.id) { n in
                n.isExpanded.toggle()
                // Lazy-load children on first expand
                if n.isExpanded && n.children == nil {
                    n.children = []
                    let path = n.path
                    let gen = self.loadGeneration
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let children = await self.scanDirectory(path)
                        guard gen == self.loadGeneration else { return }
                        var current = self.rootNodes
                        let _ = self.findAndUpdate(in: &current, id: node.id) { n in
                            n.children = children
                        }
                        self.rootNodes = current
                    }
                }
            }
            rootNodes = updated
        }
    }

    func refresh() {
        guard !rootPath.isEmpty else { return }
        // Preserve expanded state across refresh
        let expandedIds = collectExpandedIds(rootNodes)
        loadGeneration += 1
        let generation = loadGeneration
        Task {
            let nodes = await scanDirectory(rootPath)
            guard generation == self.loadGeneration else { return }
            let result = await restoreExpandedTree(nodes, expandedIds: expandedIds)
            guard generation == self.loadGeneration else { return }
            self.rootNodes = result
        }
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        refresh()
    }

    // MARK: - Private

    private func scanDirectory(_ path: String) async -> [FileTreeNode] {
        let showHidden = showHiddenFiles
        return await Task.detached {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
                return [FileTreeNode]()
            }

            var nodes: [FileTreeNode] = []
            for name in contents {
                let isHidden = name.hasPrefix(".")
                if isHidden && !showHidden { continue }

                let fullPath = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)

                nodes.append(FileTreeNode(
                    id: fullPath,
                    name: name,
                    path: fullPath,
                    isDirectory: isDir.boolValue,
                    isHidden: isHidden,
                    children: isDir.boolValue ? nil : []
                ))
            }

            // Sort: directories first, then alphabetical (case-insensitive)
            nodes.sort { a, b in
                if a.isDirectory != b.isDirectory {
                    return a.isDirectory
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            return nodes
        }.value
    }

    @discardableResult
    private func findAndUpdate(
        in nodes: inout [FileTreeNode],
        id: String,
        transform: (inout FileTreeNode) -> Void
    ) -> Bool {
        for i in nodes.indices {
            if nodes[i].id == id {
                transform(&nodes[i])
                return true
            }
            if var children = nodes[i].children {
                if findAndUpdate(in: &children, id: id, transform: transform) {
                    nodes[i].children = children
                    return true
                }
            }
        }
        return false
    }

    private func collectExpandedIds(_ nodes: [FileTreeNode]) -> Set<String> {
        var ids = Set<String>()
        for node in nodes {
            if node.isExpanded {
                ids.insert(node.id)
            }
            if let children = node.children {
                ids.formUnion(collectExpandedIds(children))
            }
        }
        return ids
    }

    private func restoreExpandedTree(_ nodes: [FileTreeNode], expandedIds: Set<String>) async -> [FileTreeNode] {
        var result = nodes
        for i in result.indices {
            let shouldExpand = expandedIds.contains(result[i].id) && result[i].isDirectory
            if shouldExpand {
                result[i].isExpanded = true
            }

            if shouldExpand && result[i].children == nil {
                // Lazy-load children for expanded dirs, then recurse
                let children = await scanDirectory(result[i].path)
                result[i].children = await restoreExpandedTree(children, expandedIds: expandedIds)
            } else if let children = result[i].children {
                result[i].children = await restoreExpandedTree(children, expandedIds: expandedIds)
            }
        }
        return result
    }
}
