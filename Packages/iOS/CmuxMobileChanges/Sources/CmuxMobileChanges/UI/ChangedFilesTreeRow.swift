/// One visible row of the hierarchical changed-files list.
enum ChangedFilesTreeRow: Identifiable, Sendable, Equatable {
    case directory(DirectoryRowSnapshot)
    case file(FileRowSnapshot)

    /// Immutable render input for a directory row.
    struct DirectoryRowSnapshot: Sendable, Equatable {
        /// Full repository-relative directory path; expansion identity.
        let path: String
        let displayName: String
        let depth: Int
        /// Number of changed files anywhere below this directory.
        let fileCount: Int
        let isExpanded: Bool
    }

    /// Immutable render input for a file row at its tree depth.
    struct FileRowSnapshot: Sendable, Equatable {
        let snapshot: ChangedFileRowSnapshot
        let depth: Int
    }

    // A deleted file can coexist with a new directory of the same name in
    // one diff, so directory and file identities carry distinct prefixes.
    var id: String {
        switch self {
        case .directory(let directory): return "dir:\(directory.path)"
        case .file(let file): return "file:\(file.snapshot.file.path)"
        }
    }
}

extension ChangedFilesTree {
    /// Flattens the tree into visible rows, skipping the contents of
    /// collapsed directories. An empty set renders everything expanded,
    /// which is the initial state.
    func rows(collapsedDirectories: Set<String>) -> [ChangedFilesTreeRow] {
        var rows: [ChangedFilesTreeRow] = []
        func walk(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case .directory(let directory):
                    let isExpanded = !collapsedDirectories.contains(directory.path)
                    rows.append(.directory(ChangedFilesTreeRow.DirectoryRowSnapshot(
                        path: directory.path,
                        displayName: directory.displayName,
                        depth: directory.depth,
                        fileCount: directory.fileCount,
                        isExpanded: isExpanded
                    )))
                    if isExpanded {
                        walk(directory.children)
                    }
                case .file(let file):
                    rows.append(.file(ChangedFilesTreeRow.FileRowSnapshot(
                        snapshot: ChangedFileRowSnapshot(index: file.index, file: file.item),
                        depth: file.depth
                    )))
                }
            }
        }
        walk(nodes)
        return rows
    }
}
