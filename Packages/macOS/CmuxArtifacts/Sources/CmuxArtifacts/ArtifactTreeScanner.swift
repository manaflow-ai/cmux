import Foundation

/// Bounded recursive scanner that treats the live filesystem as authoritative.
struct ArtifactTreeScanner {
    let fileManager: FileManager
    let maximumDepth: Int
    let nodeBudget: Int

    func snapshot(paths: ArtifactStorePaths) throws -> ArtifactSnapshot {
        try Task.checkCancellation()
        var remaining = nodeBudget
        var truncated = false
        let nodes = try scanDirectory(
            paths.filesystemRoot,
            root: paths.filesystemRoot,
            depth: 0,
            remaining: &remaining,
            truncated: &truncated
        )
        return ArtifactSnapshot(
            projectRoot: paths.projectRoot,
            filesystemRoot: paths.filesystemRoot,
            nodes: nodes,
            isTruncated: truncated
        )
    }

    private func scanDirectory(
        _ directory: URL,
        root: URL,
        depth: Int,
        remaining: inout Int,
        truncated: inout Bool
    ) throws -> [ArtifactNode] {
        try Task.checkCancellation()
        guard depth <= maximumDepth, remaining > 0,
              fileManager.fileExists(atPath: directory.path) else {
            if remaining <= 0 { truncated = true }
            return []
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        guard let children = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }
        var nodes: [ArtifactNode] = []
        while let url = children.nextObject() as? URL {
            try Task.checkCancellation()
            guard remaining > 0 else {
                truncated = true
                break
            }
            guard !isManagedMarker(url), !isManagedRootEntry(url, root: root) else {
                continue
            }
            remaining -= 1
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { continue }
            guard let relativePath = relativePath(url, root: root) else { continue }
            let nested: [ArtifactNode]
            if isDirectory, depth < maximumDepth {
                nested = try scanDirectory(
                    url,
                    root: root,
                    depth: depth + 1,
                    remaining: &remaining,
                    truncated: &truncated
                )
            } else {
                nested = []
                if isDirectory, depth >= maximumDepth { truncated = true }
            }
            nodes.append(ArtifactNode(
                id: relativePath,
                name: url.lastPathComponent,
                relativePath: relativePath,
                absolutePath: url.path,
                isDirectory: isDirectory,
                fileKind: isDirectory ? nil : ArtifactFileKind.classify(url),
                size: isDirectory ? nil : values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate,
                children: nested
            ))
        }
        return nodes.sorted(by: Self.nodeOrdering)
    }

    private func isManagedMarker(_ url: URL) -> Bool {
        url.lastPathComponent == ArtifactPathResolver.workspaceMarkerName
            || url.lastPathComponent == ArtifactPathResolver.sessionMarkerName
    }

    private func isManagedRootEntry(
        _ url: URL,
        root: URL
    ) -> Bool {
        let resolver = ArtifactPathResolver()
        if resolver.refersToSameLocation(
            url,
            root.appendingPathComponent(".metadata", isDirectory: true)
        ) { return true }
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            return false
        }
        return url.lastPathComponent.hasPrefix(".")
            || ["artifacts.json", "cmux.json", "dock.json"].contains(url.lastPathComponent)
    }

    private func relativePath(_ url: URL, root: URL) -> String? {
        ArtifactPathResolver().relativePath(url, root: root)
    }

    private static func nodeOrdering(_ lhs: ArtifactNode, _ rhs: ArtifactNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
