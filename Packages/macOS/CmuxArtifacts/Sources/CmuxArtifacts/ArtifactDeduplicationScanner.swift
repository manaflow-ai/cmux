import Foundation

/// Exhaustively streams ordinary artifact files for stale-provenance recovery.
struct ArtifactDeduplicationScanner {
    let fileManager: FileManager
    let maximumDepth: Int
    let nodeLimit: Int
    let hashByteLimit: Int64

    init(
        fileManager: FileManager,
        maximumDepth: Int = 32,
        nodeLimit: Int = 100_000,
        hashByteLimit: Int64 = 512 * 1024 * 1024
    ) {
        self.fileManager = fileManager
        self.maximumDepth = max(1, maximumDepth)
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
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: paths.artifactsRoot,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return }
        let pathResolver = ArtifactPathResolver()

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard remainingNodes > 0 else { return }
            remainingNodes -= 1
            if pathResolver.refersToSameLocation(url, paths.metadataRoot) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true,
                  pathResolver.isInsideStore(url, paths: paths) else {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true {
                let relativeDepth = pathResolver.relativePath(url, root: paths.artifactsRoot)?
                    .split(separator: "/").count ?? Int.max
                if relativeDepth > maximumDepth {
                    enumerator.skipDescendants()
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
            if visitor(url, size) { return }
        }
    }
}
