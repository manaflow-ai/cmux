import Foundation

/// Hierarchical directory tree derived from ordered Git status entries.
struct MobileDiffTree: Equatable, Sendable {
    struct Directory: Equatable, Sendable {
        let path: String
        let name: String
        let directories: [Directory]
        let files: [MobileDiffFileChange]

        var fileCount: Int {
            files.count + directories.reduce(0) { $0 + $1.fileCount }
        }
    }

    enum Row: Identifiable, Equatable, Sendable {
        case directory(path: String, name: String, depth: Int, fileCount: Int)
        case file(MobileDiffFileChange, depth: Int)

        var id: String {
            switch self {
            case let .directory(path, _, _, _): "directory:\(path)"
            case let .file(file, _): "file:\(file.path)"
            }
        }
    }

    let roots: [Directory]
    let rootFiles: [MobileDiffFileChange]

    init(files: [MobileDiffFileChange]) {
        let builder = Builder(files: files)
        roots = builder.root.directories.map { builder.freeze($0) }
        rootFiles = builder.root.files
    }

    func visibleRows(collapsedDirectories: Set<String>) -> [Row] {
        var rows = rootFiles.map { Row.file($0, depth: 0) }
        for directory in roots {
            append(directory, depth: 0, collapsedDirectories: collapsedDirectories, to: &rows)
        }
        return rows
    }

    private func append(
        _ directory: Directory,
        depth: Int,
        collapsedDirectories: Set<String>,
        to rows: inout [Row]
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

private extension MobileDiffTree {
    final class MutableDirectory {
        let path: String
        let name: String
        var directories: [MutableDirectory] = []
        var files: [MobileDiffFileChange] = []

        init(path: String, name: String) {
            self.path = path
            self.name = name
        }
    }

    struct Builder {
        let root = MutableDirectory(path: "", name: "")

        init(files: [MobileDiffFileChange]) {
            for file in files {
                insert(file)
            }
        }

        func freeze(_ directory: MutableDirectory) -> Directory {
            Directory(
                path: directory.path,
                name: directory.name,
                directories: directory.directories.map(freeze),
                files: directory.files
            )
        }

        private func insert(_ file: MobileDiffFileChange) {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard components.count > 1 else {
                root.files.append(file)
                return
            }
            var parent = root
            var pathComponents: [String] = []
            for name in components.dropLast() {
                pathComponents.append(name)
                let path = pathComponents.joined(separator: "/")
                if let existing = parent.directories.first(where: { $0.name == name }) {
                    parent = existing
                } else {
                    let directory = MutableDirectory(path: path, name: name)
                    parent.directories.append(directory)
                    parent = directory
                }
            }
            parent.files.append(file)
        }
    }
}
