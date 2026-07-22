import Foundation

/// Exhaustively streams ordinary artifact files for stale-provenance recovery.
struct ArtifactDeduplicationScanner {
    let fileManager: FileManager

    /// Visits size-matching files without materializing the artifact tree.
    ///
    /// The visitor returns `true` once every requested digest has been found.
    func scanFiles(
        paths: ArtifactStorePaths,
        matchingSizes: Set<Int64>,
        until visitor: (URL, Int64) -> Bool
    ) throws {
        guard !matchingSizes.isEmpty else { return }
        _ = try scanDirectory(
            paths.artifactsRoot,
            paths: paths,
            matchingSizes: matchingSizes,
            visitor: visitor
        )
    }

    private func scanDirectory(
        _ directory: URL,
        paths: ArtifactStorePaths,
        matchingSizes: Set<Int64>,
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
            guard matchingSizes.contains(size) else { continue }
            if visitor(url, size) { return true }
        }
        return false
    }
}
