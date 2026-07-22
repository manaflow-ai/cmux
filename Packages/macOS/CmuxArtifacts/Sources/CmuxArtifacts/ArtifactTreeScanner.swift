import Foundation

/// Bounded recursive scanner that treats the live filesystem as authoritative.
struct ArtifactTreeScanner {
    let fileManager: FileManager
    let maximumDepth: Int
    let nodeBudget: Int

    func snapshot(paths: ArtifactStorePaths) throws -> ArtifactSnapshot {
        var remaining = nodeBudget
        var truncated = false
        let nodes = try scanDirectory(
            paths.artifactsRoot,
            root: paths.artifactsRoot,
            depth: 0,
            remaining: &remaining,
            truncated: &truncated
        )
        return ArtifactSnapshot(
            projectRoot: paths.projectRoot,
            artifactsRoot: paths.artifactsRoot,
            nodes: nodes,
            isTruncated: truncated
        )
    }

    func firstFile(
        paths: ArtifactStorePaths,
        matching predicate: (URL) -> Bool
    ) -> URL? {
        guard fileManager.fileExists(atPath: paths.artifactsRoot.path) else { return nil }
        guard let enumerator = fileManager.enumerator(
            at: paths.artifactsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator {
            if isManagedMetadataRoot(url, artifactsRoot: paths.artifactsRoot) {
                enumerator.skipDescendants()
                continue
            }
            if isManagedMarker(url) { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else { continue }
            if predicate(url) { return url }
        }
        return nil
    }

    private func scanDirectory(
        _ directory: URL,
        root: URL,
        depth: Int,
        remaining: inout Int,
        truncated: inout Bool
    ) throws -> [ArtifactNode] {
        guard depth <= maximumDepth, remaining > 0,
              fileManager.fileExists(atPath: directory.path) else {
            if remaining <= 0 { truncated = true }
            return []
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        var nodes: [ArtifactNode] = []
        for url in children where !isManagedMarker(url) && !isManagedMetadataRoot(url, artifactsRoot: root) {
            guard remaining > 0 else {
                truncated = true
                break
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { continue }
            guard let relativePath = relativePath(url, root: root) else { continue }
            remaining -= 1
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

    private func isManagedMetadataRoot(_ url: URL, artifactsRoot: URL) -> Bool {
        ArtifactPathResolver().refersToSameLocation(
            url,
            artifactsRoot.appendingPathComponent(".cmux", isDirectory: true)
        )
    }

    private func relativePath(_ url: URL, root: URL) -> String? {
        ArtifactPathResolver().relativePath(url, root: root)
    }

    private static func nodeOrdering(_ lhs: ArtifactNode, _ rhs: ArtifactNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
