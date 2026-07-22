import Foundation

/// Plans every path an automatic batch might write before persistence begins.
struct ArtifactAutomaticWritePlanner {
    let fileManager: FileManager
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    let nodeBudget: Int

    func plan(
        prepared: [PreparedArtifactImport],
        existingByDigest: [String: URL],
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths
    ) -> ArtifactAutomaticWritePlan {
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

        for item in prepared where item.candidate.provenance != .manual {
            destinations.append(recorder.metadataURL(paths: paths, digest: item.digest))
            let source = item.candidate.sourceURL
            guard !resolver.isInsideStore(source, paths: paths),
                  existingByDigest[item.digest] == nil else {
                continue
            }
            if captureResolution == nil {
                captureResolution = ArtifactCaptureDirectoryFinder(
                    fileManager: fileManager,
                    decoder: decoder,
                    nodeBudget: nodeBudget
                ).resolve(paths: paths, context: context, pathResolver: resolver)
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
        return ArtifactAutomaticWritePlan(
            destinations: destinations.filter {
                seen.insert($0.standardizedFileURL.path).inserted
            },
            copyDestinationBySnapshotPath: copyDestinationBySnapshotPath,
            captureResolution: captureResolution
        )
    }

    private func missingMarkerURLs(
        resolution: ArtifactCaptureDirectoryResolution
    ) -> [URL] {
        var urls: [URL] = []
        if !resolution.reusedSessionMarker {
            let workspaceMarker = resolution.directory
                .deletingLastPathComponent()
                .appendingPathComponent(ArtifactPathResolver.workspaceMarkerName)
            if !fileManager.fileExists(atPath: workspaceMarker.path) {
                urls.append(workspaceMarker)
            }
        }
        let sessionMarker = resolution.directory
            .appendingPathComponent(ArtifactPathResolver.sessionMarkerName)
        if !fileManager.fileExists(atPath: sessionMarker.path) {
            urls.append(sessionMarker)
        }
        return urls
    }
}
