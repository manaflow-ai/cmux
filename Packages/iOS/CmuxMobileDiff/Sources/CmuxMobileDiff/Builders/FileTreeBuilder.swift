internal import CmuxMobileRPC

/// Folds changed paths into a sorted, GitHub-style compressed directory tree.
struct FileTreeBuilder: Sendable {
    /// Creates a file tree builder.
    init() {}

    /// Builds directory-first alphabetical roots from changed files.
    /// - Parameter files: Changed-file summaries.
    /// - Returns: Compressed root nodes.
    func build(files: [MobileChangesFile]) -> [FileTreeNode] {
        var root = TrieNode(name: "", path: "")
        for file in files {
            root.insert(file: file, components: file.path.split(separator: "/").map(String.init))
        }
        return root.children.values.map(makeNode).sorted(by: ordered)
    }

    private struct TrieNode {
        let name: String
        let path: String
        var children: [String: TrieNode] = [:]
        var file: MobileChangesFile?

        mutating func insert(file: MobileChangesFile, components: [String]) {
            guard let first = components.first else {
                self.file = file
                return
            }
            let childPath = path.isEmpty ? first : "\(path)/\(first)"
            var child = children[first] ?? TrieNode(name: first, path: childPath)
            child.insert(file: file, components: Array(components.dropFirst()))
            children[first] = child
        }
    }

    private func makeNode(_ trie: TrieNode) -> FileTreeNode {
        if let file = trie.file {
            return FileTreeNode(id: trie.path, name: trie.name, kind: .file, children: [], file: file)
        }
        var names = [trie.name]
        var cursor = trie
        while cursor.file == nil, cursor.children.count == 1,
              let child = cursor.children.values.first, child.file == nil {
            names.append(child.name)
            cursor = child
        }
        let children = cursor.children.values.map(makeNode).sorted(by: ordered)
        return FileTreeNode(
            id: cursor.path,
            name: names.joined(separator: "/"),
            kind: .directory,
            children: children,
            file: nil
        )
    }

    private func ordered(_ lhs: FileTreeNode, _ rhs: FileTreeNode) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind == .directory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
