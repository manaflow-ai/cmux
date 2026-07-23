import Foundation

/// Bounded catalog of live directories carrying decodable cmux identity markers.
struct ArtifactMarkerDirectoryCatalog {
    let fileManager: FileManager
    let decoder: JSONDecoder
    let nodeBudget: Int

    func sessionDirectories(
        paths: ArtifactStorePaths,
        pathResolver: ArtifactPathResolver
    ) throws -> [(directory: URL, marker: ArtifactSessionMarker)] {
        try markerDirectories(
            paths: paths,
            markerName: ArtifactPathResolver.sessionMarkerName,
            pathResolver: pathResolver
        )
    }

    func workspaceDirectories(
        paths: ArtifactStorePaths,
        pathResolver: ArtifactPathResolver
    ) throws -> [(directory: URL, marker: ArtifactWorkspaceMarker)] {
        try markerDirectories(
            paths: paths,
            markerName: ArtifactPathResolver.workspaceMarkerName,
            pathResolver: pathResolver
        )
    }

    private func markerDirectories<Marker: Decodable>(
        paths: ArtifactStorePaths,
        markerName: String,
        pathResolver: ArtifactPathResolver
    ) throws -> [(directory: URL, marker: Marker)] {
        guard let enumerator = fileManager.enumerator(
            at: paths.filesystemRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var entries: [(directory: URL, marker: Marker)] = []
        var visited = 0
        var exceededNodeBudget = false
        for case let url as URL in enumerator {
            guard visited < nodeBudget else {
                exceededNodeBudget = true
                break
            }
            visited += 1
            if pathResolver.refersToSameLocation(url, paths.metadataRoot) {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == markerName,
                  let data = try? ArtifactBoundedFileReader().data(
                      url: url,
                      allowedRoot: paths.filesystemRoot,
                      maximumBytes: 256 * 1024
                  ),
                  let marker = try? decoder.decode(Marker.self, from: data) else {
                continue
            }
            let directory = url.deletingLastPathComponent()
            guard let relativePath = pathResolver.relativePath(
                directory,
                root: paths.filesystemRoot
            ) else {
                continue
            }
            entries.append((
                directory: paths.filesystemRoot.appendingPathComponent(
                    relativePath,
                    isDirectory: true
                ),
                marker: marker
            ))
        }
        guard !exceededNodeBudget else {
            throw ArtifactStoreError.scanIncomplete(paths.filesystemRoot.path)
        }
        return entries.sorted {
            $0.directory.path.localizedStandardCompare($1.directory.path) == .orderedAscending
        }
    }
}
