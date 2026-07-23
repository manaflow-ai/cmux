import Foundation

/// Reuses cmux-managed grouping markers after users move or rename folders.
struct ArtifactCaptureDirectoryFinder {
    let fileManager: FileManager
    let decoder: JSONDecoder
    let nodeBudget: Int

    func resolve(
        paths: ArtifactStorePaths,
        context: ArtifactCaptureContext,
        pathResolver: ArtifactPathResolver,
        kind: CmuxSessionContentKind = .artifacts
    ) throws -> ArtifactCaptureDirectoryResolution {
        let sessionID = normalized(context.sessionID)
        if let sessionID,
           let sessionRoot = try markerDirectories(
               paths: paths,
               markerName: ArtifactPathResolver.sessionMarkerName,
               pathResolver: pathResolver,
               matches: { (marker: ArtifactSessionMarker) in marker.sessionID == sessionID }
           ).first {
            return ArtifactCaptureDirectoryResolution(
                directory: sessionRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
            )
        }

        let fallback = pathResolver.contentDirectory(paths: paths, context: context, kind: kind)
        if let sessionID {
            try validateFallbackSessionMarker(
                fallback: fallback,
                sessionID: sessionID,
                paths: paths
            )
            return ArtifactCaptureDirectoryResolution(directory: fallback)
        }
        guard sessionID == nil,
              let workspaceID = normalized(context.workspaceID),
              let sessionRoot = try markerDirectories(
                  paths: paths,
                  markerName: ArtifactPathResolver.workspaceMarkerName,
                  pathResolver: pathResolver,
                  matches: { (marker: ArtifactWorkspaceMarker) in marker.workspaceID == workspaceID }
              ).first else {
            return ArtifactCaptureDirectoryResolution(directory: fallback)
        }
        return ArtifactCaptureDirectoryResolution(
            directory: sessionRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
        )
    }

    private func validateFallbackSessionMarker(
        fallback: URL,
        sessionID: String,
        paths: ArtifactStorePaths
    ) throws {
        let markerURL = fallback.deletingLastPathComponent()
            .appendingPathComponent(ArtifactPathResolver.sessionMarkerName)
        let reader = ArtifactBoundedFileReader()
        guard try reader.pathEntryExists(url: markerURL) else { return }
        guard let data = try reader.data(
            url: markerURL,
            allowedRoot: paths.filesystemRoot,
            maximumBytes: 256 * 1024
        ), let marker = try? decoder.decode(ArtifactSessionMarker.self, from: data),
              marker.sessionID == sessionID else {
            throw ArtifactStoreError.corruptProvenance(markerURL.path)
        }
    }

    private func markerDirectories<Marker: Decodable>(
        paths: ArtifactStorePaths,
        markerName: String,
        pathResolver: ArtifactPathResolver,
        matches: (Marker) -> Bool
    ) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: paths.filesystemRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var directories: [URL] = []
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
                  let marker = try? decoder.decode(Marker.self, from: data),
                  matches(marker) else {
                continue
            }
            let directory = url.deletingLastPathComponent()
            guard let relativePath = pathResolver.relativePath(directory, root: paths.filesystemRoot) else {
                continue
            }
            directories.append(
                paths.filesystemRoot.appendingPathComponent(relativePath, isDirectory: true)
            )
        }
        guard !exceededNodeBudget else {
            throw ArtifactStoreError.scanIncomplete(paths.filesystemRoot.path)
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
