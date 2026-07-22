import Foundation

/// Exhaustively streams ordinary artifact files for stale-provenance recovery.
struct ArtifactDeduplicationScanner {
    let fileManager: FileManager
    let nodeLimit: Int
    let hashByteLimit: Int64

    init(
        fileManager: FileManager,
        nodeLimit: Int = 100_000,
        hashByteLimit: Int64 = 512 * 1024 * 1024
    ) {
        self.fileManager = fileManager
        self.nodeLimit = max(1, nodeLimit)
        self.hashByteLimit = max(1, hashByteLimit)
    }

    /// Visits size-matching files without materializing the artifact tree.
    ///
    /// The visitor returns `true` once every requested digest has been found.
    func scanFiles(
        paths: ArtifactStorePaths,
        matchingSizes: Set<Int64>,
        until visitor: (URL, Int64) -> Bool
    ) throws {
        guard !matchingSizes.isEmpty else { return }
        try Task.checkCancellation()
        var remainingNodes = nodeLimit
        var remainingHashBytes = hashByteLimit
        _ = try scanDirectory(
            paths.artifactsRoot,
            paths: paths,
            matchingSizes: matchingSizes,
            remainingNodes: &remainingNodes,
            remainingHashBytes: &remainingHashBytes,
            visitor: visitor
        )
    }

    private func scanDirectory(
        _ directory: URL,
        paths: ArtifactStorePaths,
        matchingSizes: Set<Int64>,
        remainingNodes: inout Int,
        remainingHashBytes: inout Int64,
        visitor: (URL, Int64) -> Bool
    ) throws -> Bool {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let children = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants]
        ) else { return false }
        let pathResolver = ArtifactPathResolver()
        while let url = children.nextObject() as? URL {
            try Task.checkCancellation()
            guard remainingNodes > 0 else { return true }
            remainingNodes -= 1
            if pathResolver.refersToSameLocation(url, paths.metadataRoot) {
                continue
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true,
                  pathResolver.isInsideStore(url, paths: paths) else {
                continue
            }
            if values.isDirectory == true {
                if try scanDirectory(
                    url,
                    paths: paths,
                    matchingSizes: matchingSizes,
                    remainingNodes: &remainingNodes,
                    remainingHashBytes: &remainingHashBytes,
                    visitor: visitor
                ) {
                    return true
                }
                continue
            }
            guard values.isRegularFile == true,
                  url.lastPathComponent != ArtifactPathResolver.workspaceMarkerName,
                  url.lastPathComponent != ArtifactPathResolver.sessionMarkerName,
                  let rawSize = values.fileSize else {
                continue
            }
            let size = Int64(rawSize)
            guard matchingSizes.contains(size), size <= remainingHashBytes else { continue }
            remainingHashBytes -= size
            if visitor(url, size) { return true }
        }
        return false
    }
}
