internal import Foundation

/// Hierarchical grouping of a changed-file snapshot by directory, in the
/// GitHub file-tree shape: directories sort before files, siblings sort
/// case-insensitively, and directory chains with a single child directory
/// and no files collapse into one node ("Sources/UI" rather than two rows).
struct ChangedFilesTree: Sendable, Equatable {
    /// One branch or leaf of the built tree.
    enum Node: Sendable, Equatable {
        case directory(Directory)
        case file(File)
    }

    /// A directory containing at least one changed file somewhere below it.
    struct Directory: Sendable, Equatable {
        /// Full repository-relative directory path; stable identity for
        /// expansion state, including through chain flattening.
        let path: String
        /// Rendered name; a flattened chain joins its segments with "/".
        let displayName: String
        /// Nesting level in the rendered tree, where a flattened chain
        /// counts as one level.
        let depth: Int
        /// Number of changed files anywhere below this directory.
        let fileCount: Int
        /// Ordered children: subdirectories first, then files.
        let children: [Node]
    }

    /// A changed file positioned in the tree.
    struct File: Sendable, Equatable {
        /// The file's stable position in the flat path-sorted snapshot,
        /// preserved so selection still addresses the original array.
        let index: Int
        let item: ChangedFileItem
        let depth: Int
    }

    /// Ordered top-level nodes.
    let nodes: [Node]

    /// Builds the tree for one flat changed-file snapshot.
    static func build(from files: [ChangedFileItem]) -> ChangedFilesTree {
        final class DirectoryBuilder {
            var subdirectories: [String: DirectoryBuilder] = [:]
            var files: [(name: String, index: Int, item: ChangedFileItem)] = []
        }

        let root = DirectoryBuilder()
        for (index, item) in files.enumerated() {
            let components = item.path.split(separator: "/").map(String.init)
            var directory = root
            for component in components.dropLast() {
                if let existing = directory.subdirectories[component] {
                    directory = existing
                } else {
                    let created = DirectoryBuilder()
                    directory.subdirectories[component] = created
                    directory = created
                }
            }
            directory.files.append((components.last ?? item.path, index, item))
        }

        func convert(
            _ builder: DirectoryBuilder,
            name: String,
            parentPath: String,
            depth: Int
        ) -> Node {
            var segments = [name]
            var path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
            var current = builder
            while current.files.isEmpty, current.subdirectories.count == 1,
                  let (childName, child) = current.subdirectories.first {
                segments.append(childName)
                path += "/\(childName)"
                current = child
            }
            let children = convertChildren(of: current, parentPath: path, depth: depth + 1)
            let fileCount = children.reduce(0) { count, child in
                switch child {
                case .directory(let directory): return count + directory.fileCount
                case .file: return count + 1
                }
            }
            return .directory(Directory(
                path: path,
                displayName: segments.joined(separator: "/"),
                depth: depth,
                fileCount: fileCount,
                children: children
            ))
        }

        func convertChildren(
            of builder: DirectoryBuilder,
            parentPath: String,
            depth: Int
        ) -> [Node] {
            let directories = builder.subdirectories
                .sorted { precedes($0.key, $1.key) }
                .map { convert($0.value, name: $0.key, parentPath: parentPath, depth: depth) }
            let files = builder.files
                .sorted { precedes($0.name, $1.name) }
                .map { Node.file(File(index: $0.index, item: $0.item, depth: depth)) }
            return directories + files
        }

        return ChangedFilesTree(nodes: convertChildren(of: root, parentPath: "", depth: 0))
    }

    /// Case-insensitive sibling order with a case-sensitive tiebreak so
    /// equal-ignoring-case names still sort deterministically.
    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.caseInsensitiveCompare(rhs) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs < rhs
        }
    }
}
