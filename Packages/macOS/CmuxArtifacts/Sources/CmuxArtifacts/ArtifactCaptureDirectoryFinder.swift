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
        let sessionIdentity = context.sessionIdentity
        let markerCatalog = ArtifactMarkerDirectoryCatalog(
            fileManager: fileManager,
            decoder: decoder,
            nodeBudget: nodeBudget
        )
        if sessionIdentity.sessionID != nil {
            let matches = try markerCatalog.sessionDirectories(
                paths: paths,
                pathResolver: pathResolver
            ).filter { $0.marker.identity == sessionIdentity }.map(\.directory)
            if let sessionRoot = try uniqueDirectory(matches, paths: paths) {
                return ArtifactCaptureDirectoryResolution(
                    directory: sessionRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
                )
            }
        }

        let fallback = pathResolver.contentDirectory(paths: paths, context: context, kind: kind)
        if sessionIdentity.sessionID != nil {
            try validateFallbackSessionMarker(
                fallback: fallback,
                sessionIdentity: sessionIdentity,
                paths: paths
            )
            return ArtifactCaptureDirectoryResolution(directory: fallback)
        }
        guard let workspaceID = normalized(context.workspaceID) else {
            return ArtifactCaptureDirectoryResolution(directory: fallback)
        }
        let workspaceDirectoryPaths = Set(
            try markerCatalog.workspaceDirectories(
                paths: paths,
                pathResolver: pathResolver
            ).filter { $0.marker.workspaceID == workspaceID }
                .map { $0.directory.standardizedFileURL.path }
        )
        let matches = try markerCatalog.sessionDirectories(
            paths: paths,
            pathResolver: pathResolver
        ).filter {
            $0.marker.identity == sessionIdentity
                && workspaceDirectoryPaths.contains($0.directory.standardizedFileURL.path)
        }.map(\.directory)
        guard let sessionRoot = try uniqueDirectory(matches, paths: paths) else {
            return ArtifactCaptureDirectoryResolution(directory: fallback)
        }
        return ArtifactCaptureDirectoryResolution(
            directory: sessionRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
        )
    }

    private func validateFallbackSessionMarker(
        fallback: URL,
        sessionIdentity: ArtifactSessionIdentity,
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
              marker.identity == sessionIdentity else {
            throw ArtifactStoreError.corruptProvenance(markerURL.path)
        }
    }

    private func uniqueDirectory(
        _ matches: [URL],
        paths: ArtifactStorePaths
    ) throws -> URL? {
        guard matches.count <= 1 else {
            throw ArtifactStoreError.corruptProvenance(paths.filesystemRoot.path)
        }
        return matches.first
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
