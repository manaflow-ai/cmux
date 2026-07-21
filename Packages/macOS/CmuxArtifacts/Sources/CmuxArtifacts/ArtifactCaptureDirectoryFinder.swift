import Foundation

/// Reuses cmux-managed grouping markers after users move or rename folders.
struct ArtifactCaptureDirectoryFinder {
    let fileManager: FileManager
    let decoder: JSONDecoder
    let nodeBudget: Int

    func resolve(
        paths: ArtifactStorePaths,
        context: ArtifactCaptureContext,
        pathResolver: ArtifactPathResolver
    ) -> ArtifactCaptureDirectoryResolution {
        if let sessionID = normalized(context.sessionID),
           let directory = markerDirectories(
               paths: paths,
               markerName: ArtifactPathResolver.sessionMarkerName,
               pathResolver: pathResolver,
               matches: { (marker: ArtifactSessionMarker) in marker.sessionID == sessionID }
           ).first {
            return ArtifactCaptureDirectoryResolution(directory: directory, reusedSessionMarker: true)
        }

        let fallback = pathResolver.captureDirectory(paths: paths, context: context)
        guard let workspaceID = normalized(context.workspaceID),
              let workspaceDirectory = markerDirectories(
                  paths: paths,
                  markerName: ArtifactPathResolver.workspaceMarkerName,
                  pathResolver: pathResolver,
                  matches: { (marker: ArtifactWorkspaceMarker) in marker.workspaceID == workspaceID }
              ).first else {
            return ArtifactCaptureDirectoryResolution(directory: fallback, reusedSessionMarker: false)
        }
        return ArtifactCaptureDirectoryResolution(
            directory: workspaceDirectory.appendingPathComponent(
                fallback.lastPathComponent,
                isDirectory: true
            ),
            reusedSessionMarker: false
        )
    }

    private func markerDirectories<Marker: Decodable>(
        paths: ArtifactStorePaths,
        markerName: String,
        pathResolver: ArtifactPathResolver,
        matches: (Marker) -> Bool
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: paths.artifactsRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var directories: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            guard visited < nodeBudget else { break }
            visited += 1
            if pathResolver.refersToSameLocation(url, paths.metadataRoot) {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == markerName,
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size <= 256 * 1024,
                  let data = try? Data(contentsOf: url),
                  let marker = try? decoder.decode(Marker.self, from: data),
                  matches(marker) else {
                continue
            }
            let directory = url.deletingLastPathComponent()
            guard let relativePath = pathResolver.relativePath(directory, root: paths.artifactsRoot) else {
                continue
            }
            directories.append(
                paths.artifactsRoot.appendingPathComponent(relativePath, isDirectory: true)
            )
        }
        return directories.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
