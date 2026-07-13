import Foundation

/// Hierarchical directory tree derived from ordered Git status entries.
struct MobileDiffTree: Equatable, Sendable {
    let roots: [MobileDiffTreeDirectory]
    let rootFiles: [MobileDiffFileChange]

    init(files: [MobileDiffFileChange]) {
        let builder = MobileDiffTreeBuilder(files: files)
        roots = builder.root.directories.map { builder.freeze($0) }
        rootFiles = builder.root.files
    }

    func visibleRows(collapsedDirectories: Set<String>) -> [MobileDiffTreeRow] {
        var rows = rootFiles.map { MobileDiffTreeRow.file($0, depth: 0) }
        for directory in roots {
            append(directory, depth: 0, collapsedDirectories: collapsedDirectories, to: &rows)
        }
        return rows
    }

    private func append(
        _ directory: MobileDiffTreeDirectory,
        depth: Int,
        collapsedDirectories: Set<String>,
        to rows: inout [MobileDiffTreeRow]
    ) {
        rows.append(.directory(
            path: directory.path,
            name: directory.name,
            depth: depth,
            fileCount: directory.fileCount
        ))
        guard !collapsedDirectories.contains(directory.path) else { return }
        for file in directory.files {
            rows.append(.file(file, depth: depth + 1))
        }
        for child in directory.directories {
            append(child, depth: depth + 1, collapsedDirectories: collapsedDirectories, to: &rows)
        }
    }
}
