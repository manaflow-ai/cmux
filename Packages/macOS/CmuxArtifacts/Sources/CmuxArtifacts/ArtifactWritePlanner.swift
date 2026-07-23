import Foundation

/// Plans every path an import batch might write before persistence begins.
struct ArtifactWritePlanner {
    let fileManager: FileManager
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let nodeBudget: Int

    func plan(
        prepared: [PreparedArtifactImport],
        existingByDigest: [String: URL],
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths
    ) throws -> ArtifactWritePlan {
        try plan(
            prepared: prepared,
            existingByDigest: existingByDigest,
            context: context,
            paths: paths,
            allowsIncompleteDiscoveryFallback: false
        )
    }

    /// Plans potential writes without deduplication for pre-lease Git authorization.
    ///
    /// If bounded marker discovery is incomplete, this plan authorizes only the
    /// deterministic fallback. The authoritative plan must still be its subset.
    func conservativePlan(
        prepared: [PreparedArtifactImport],
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths
    ) throws -> ArtifactWritePlan {
        try plan(
            prepared: prepared,
            existingByDigest: [:],
            context: context,
            paths: paths,
            allowsIncompleteDiscoveryFallback: true
        )
    }

    private func plan(
        prepared: [PreparedArtifactImport],
        existingByDigest: [String: URL],
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths,
        allowsIncompleteDiscoveryFallback: Bool
    ) throws -> ArtifactWritePlan {
        let resolver = ArtifactPathResolver()
        let recorder = ArtifactProvenanceRecorder(
            fileManager: fileManager,
            encoder: encoder,
            decoder: decoder
        )
        var destinations: [URL] = []
        var copyDestinationBySnapshotPath: [String: URL] = [:]
        var reservedDestinationPaths: Set<String> = []
        var captureResolution: ArtifactCaptureDirectoryResolution?

        for item in prepared {
            destinations.append(recorder.metadataURL(paths: paths, digest: item.digest))
            let source = item.candidate.sourceURL
            guard !resolver.isInsideStore(source, paths: paths),
                  existingByDigest[item.digest] == nil else {
                continue
            }
            if captureResolution == nil {
                captureResolution = try resolveCaptureDirectory(
                    paths: paths,
                    context: context,
                    pathResolver: resolver,
                    allowsIncompleteDiscoveryFallback: allowsIncompleteDiscoveryFallback
                )
            }
            guard let captureResolution else { continue }
            let destination = resolver.uniqueDestination(
                source: source,
                directory: captureResolution.directory,
                fileManager: fileManager,
                reservedPaths: reservedDestinationPaths
            )
            reservedDestinationPaths.insert(destination.standardizedFileURL.path)
            copyDestinationBySnapshotPath[item.snapshot.url.standardizedFileURL.path] = destination
            destinations.append(destination)
        }
        if let captureResolution {
            destinations.append(contentsOf: missingMarkerURLs(resolution: captureResolution))
        }
        var seen: Set<String> = []
        return ArtifactWritePlan(
            destinations: destinations.filter {
                seen.insert($0.standardizedFileURL.path).inserted
            },
            copyDestinationBySnapshotPath: copyDestinationBySnapshotPath,
            captureResolution: captureResolution
        )
    }

    private func resolveCaptureDirectory(
        paths: ArtifactStorePaths,
        context: ArtifactCaptureContext,
        pathResolver: ArtifactPathResolver,
        allowsIncompleteDiscoveryFallback: Bool
    ) throws -> ArtifactCaptureDirectoryResolution {
        do {
            return try ArtifactCaptureDirectoryFinder(
                fileManager: fileManager,
                decoder: decoder,
                nodeBudget: nodeBudget
            ).resolve(paths: paths, context: context, pathResolver: pathResolver)
        } catch ArtifactStoreError.scanIncomplete where allowsIncompleteDiscoveryFallback {
            return ArtifactCaptureDirectoryResolution(
                directory: pathResolver.contentDirectory(
                    paths: paths,
                    context: context,
                    kind: .artifacts
                )
            )
        }
    }

    private func missingMarkerURLs(
        resolution: ArtifactCaptureDirectoryResolution
    ) -> [URL] {
        var urls: [URL] = []
        let sessionRoot = resolution.directory.deletingLastPathComponent()
        let workspaceMarker = sessionRoot
            .appendingPathComponent(ArtifactPathResolver.workspaceMarkerName)
        if !fileManager.fileExists(atPath: workspaceMarker.path) {
            urls.append(workspaceMarker)
        }
        let sessionMarker = sessionRoot
            .appendingPathComponent(ArtifactPathResolver.sessionMarkerName)
        if !fileManager.fileExists(atPath: sessionMarker.path) {
            urls.append(sessionMarker)
        }
        return urls
    }
}
