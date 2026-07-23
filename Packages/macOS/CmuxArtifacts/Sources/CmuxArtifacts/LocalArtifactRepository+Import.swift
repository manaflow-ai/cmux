import Foundation

extension LocalArtifactRepository {
    func importPrepared(
        _ prepared: PreparedArtifactImport,
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths,
        capturedAt: Date,
        existingByDigest: inout [String: URL],
        captureDirectory: inout URL?,
        plannedDestination: URL?,
        plannedResolution: ArtifactCaptureDirectoryResolution?
    ) throws -> ArtifactImportOutcome {
        let source = prepared.candidate.sourceURL
        let size = prepared.snapshot.size
        let digest = prepared.digest
        let pathResolver = ArtifactPathResolver()

        if pathResolver.isInsideStore(source, paths: paths),
           let relativePath = pathResolver.relativePath(source, root: paths.filesystemRoot) {
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
            existingByDigest[digest] = source
            return .alreadyStored(record)
        }

        if let existing = existingByDigest[digest],
           let relativePath = pathResolver.relativePath(existing, root: paths.filesystemRoot) {
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
            return .deduplicated(record)
        }

        let resolution: ArtifactCaptureDirectoryResolution?
        let destinationDirectory: URL
        if let plannedDestination {
            destinationDirectory = plannedDestination.deletingLastPathComponent()
            resolution = captureDirectory.map {
                pathResolver.refersToSameLocation($0, destinationDirectory)
            } == true ? nil : plannedResolution
        } else if let captureDirectory {
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
        let destination = plannedDestination ?? pathResolver.uniqueDestination(
            source: source,
            directory: destinationDirectory,
            fileManager: fileManager
        )
        if let resolution {
            try createCaptureDirectory(
                resolution.directory,
                paths: paths,
                context: context,
                capturedAt: capturedAt
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
        guard let relativePath = pathResolver.relativePath(destination, root: paths.filesystemRoot) else {
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

}
