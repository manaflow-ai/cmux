import Foundation

/// Iterates from a filesystem directory through its ancestors, including the root directory.
struct ArtifactAncestorDirectories: IteratorProtocol, Sequence {
    private var nextDirectory: URL?

    init(startingAt directory: URL) {
        nextDirectory = directory.standardizedFileURL
    }

    mutating func next() -> URL? {
        guard let current = nextDirectory else { return nil }
        let currentPath = current.path
        guard currentPath != "/" else {
            nextDirectory = nil
            return current
        }

        let rawParentPath = (currentPath as NSString).deletingLastPathComponent
        let parentPath = rawParentPath.isEmpty ? "/" : rawParentPath
        guard parentPath != currentPath else {
            nextDirectory = nil
            return current
        }

        nextDirectory = URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL
        return current
    }
}
