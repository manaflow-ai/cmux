import Foundation

extension LocalArtifactRepository {
    func importPrepared(
        _ prepared: PreparedArtifactImport,
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths,
        capturedAt: Date,
        existingByDigest: inout [String: URL],
        captureDirectory: inout URL?
    ) throws -> ArtifactImportOutcome {
        let source = prepared.candidate.sourceURL
        let size = prepared.snapshot.size
        let digest = prepared.digest
        let pathResolver = ArtifactPathResolver()
        let provenanceURL = ArtifactProvenanceRecorder(
            fileManager: fileManager,
            encoder: encoder,
            decoder: decoder
        ).metadataURL(paths: paths, digest: digest)

        if pathResolver.isInsideStore(source, paths: paths),
           let relativePath = pathResolver.relativePath(source, root: paths.artifactsRoot) {
            let record = makeRecord(
                digest: digest,
                source: source,
                relativePath: relativePath,
                context: context,
                provenance: prepared.candidate.provenance,
                capturedAt: capturedAt,
                size: size
            )
            try requireGitPrivacy(
                for: prepared.candidate,
                destinations: [provenanceURL],
                paths: paths
            )
            try recordProvenance(record, paths: paths)
            existingByDigest[digest] = source
            return .alreadyStored(record)
        }

        if let existing = existingByDigest[digest],
           let relativePath = pathResolver.relativePath(existing, root: paths.artifactsRoot) {
            let record = makeRecord(
                digest: digest,
                source: source,
                relativePath: relativePath,
                context: context,
                provenance: prepared.candidate.provenance,
                capturedAt: capturedAt,
                size: size
            )
            try requireGitPrivacy(
                for: prepared.candidate,
                destinations: [provenanceURL],
                paths: paths
            )
            try recordProvenance(record, paths: paths)
            return .deduplicated(record)
        }

        let resolution: ArtifactCaptureDirectoryResolution?
        let destinationDirectory: URL
        if let captureDirectory {
            resolution = nil
            destinationDirectory = captureDirectory
        } else {
            let resolved = ArtifactCaptureDirectoryFinder(
                fileManager: fileManager,
                decoder: decoder,
                nodeBudget: nodeBudget
            ).resolve(paths: paths, context: context, pathResolver: pathResolver)
            resolution = resolved
            destinationDirectory = resolved.directory
        }
        let destination = pathResolver.uniqueDestination(
            source: source,
            directory: destinationDirectory,
            fileManager: fileManager
        )
        var writeDestinations = [destination, provenanceURL]
        if let resolution {
            writeDestinations.append(contentsOf: missingMarkerURLs(
                resolution: resolution,
                fileManager: fileManager
            ))
        }
        try requireGitPrivacy(
            for: prepared.candidate,
            destinations: writeDestinations,
            paths: paths
        )
        if let resolution {
            try createCaptureDirectory(
                resolution.directory,
                paths: paths,
                context: context,
                capturedAt: capturedAt,
                writesWorkspaceMarker: !resolution.reusedSessionMarker
            )
            captureDirectory = resolution.directory
        }

        try fileManager.moveItem(at: prepared.snapshot.url, to: destination)
        var keepsDestination = false
        defer {
            if !keepsDestination {
                try? fileManager.removeItem(at: destination)
            }
        }
        guard let relativePath = pathResolver.relativePath(destination, root: paths.artifactsRoot) else {
            throw ArtifactStoreError.pathOutsideStore(destination.path)
        }
        let record = makeRecord(
            digest: digest,
            source: source,
            relativePath: relativePath,
            context: context,
            provenance: prepared.candidate.provenance,
            capturedAt: capturedAt,
            size: size
        )
        try recordProvenance(record, paths: paths)
        existingByDigest[digest] = destination
        keepsDestination = true
        return .copied(record)
    }

    private func requireGitPrivacy(
        for candidate: ArtifactCandidate,
        destinations: [URL],
        paths: ArtifactStorePaths
    ) throws {
        guard candidate.provenance != .manual else { return }
        guard ArtifactGitIgnoreManager(fileManager: fileManager).permitsAutomaticWrites(
            projectRoot: paths.projectRoot,
            destinations: destinations,
            commandRunner: gitCommandRunner
        ) else {
            throw ArtifactStoreError.gitPrivacyUnavailable(paths.artifactsRoot.path)
        }
    }

    private func missingMarkerURLs(
        resolution: ArtifactCaptureDirectoryResolution,
        fileManager: FileManager
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
