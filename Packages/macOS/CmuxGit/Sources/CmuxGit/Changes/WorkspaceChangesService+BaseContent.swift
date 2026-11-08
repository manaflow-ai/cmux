import Foundation

extension WorkspaceChangesService {
    nonisolated func statBaseFile(
        _ authorizedFile: WorkspaceChangesAuthorizedPathCache.AuthorizedFile,
        projectedSize: Int64
    ) async throws -> WorkspaceChangesFileStat {
        let key = baseContentKey(for: authorizedFile)
        let reader = contentReader
        let fingerprint = try baseContentFingerprint(for: authorizedFile)
        return try await baseContentCache.withLeasedFileURL(
            for: key,
            projectedSize: projectedSize,
            materialize: { destination in
                try await materializeBaseContent(authorizedFile, to: destination)
            },
            operation: { fileURL in
                let stat = try reader.stat(
                    repoRoot: fileURL.deletingLastPathComponent().path,
                    relativePath: fileURL.lastPathComponent
                )
                return WorkspaceChangesFileStat(
                    artifactStat: stat.artifactStat,
                    contentFingerprint: fingerprint
                )
            }
        )
    }

    nonisolated func fetchBaseFile(
        _ authorizedFile: WorkspaceChangesAuthorizedPathCache.AuthorizedFile,
        offset: Int64,
        length: Int
    ) async throws -> WorkspaceChangesFileChunk {
        let key = baseContentKey(for: authorizedFile)
        let reader = contentReader
        let projectedSize = try requiredBaseBlobSize(for: authorizedFile)
        let fingerprint = try baseContentFingerprint(for: authorizedFile)
        return try await baseContentCache.withLeasedFileURL(
            for: key,
            projectedSize: projectedSize,
            materialize: { destination in
                try await materializeBaseContent(authorizedFile, to: destination)
            },
            operation: { fileURL in
                let chunk = try reader.fetch(
                    repoRoot: fileURL.deletingLastPathComponent().path,
                    relativePath: fileURL.lastPathComponent,
                    offset: offset,
                    length: length
                )
                return WorkspaceChangesFileChunk(
                    artifactChunk: chunk.artifactChunk,
                    contentFingerprint: fingerprint
                )
            }
        )
    }

    private nonisolated func baseContentKey(
        for authorizedFile: WorkspaceChangesAuthorizedPathCache.AuthorizedFile
    ) -> WorkspaceChangesBaseContentCache.Key {
        let scope = authorizedFile.snapshot.scope
        return WorkspaceChangesBaseContentCache.Key(
            repoRoot: scope.repoRoot,
            baseCommitOID: scope.diffBaseCommitOID,
            path: authorizedFile.relativePath
        )
    }

    private nonisolated func materializeBaseContent(
        _ authorizedFile: WorkspaceChangesAuthorizedPathCache.AuthorizedFile,
        to destination: URL
    ) async throws {
        let blobSize = try requiredBaseBlobSize(for: authorizedFile)
        let scope = authorizedFile.snapshot.scope
        guard let object = authorizedFile.baseBlobOID else {
            throw WorkspaceChangesServiceError.fileNotFound
        }
        let runner = self.runner
        let result = try await offCooperativePool {
            try runner.run(
                arguments: ["--literal-pathspecs", "show", object],
                in: URL(fileURLWithPath: scope.repoRoot, isDirectory: true),
                writingOutputTo: destination,
                maximumOutputByteCount: blobSize
            )
        }
        guard result.exitCode == 0,
              !result.standardOutputWasTruncated else {
            throw WorkspaceChangesServiceError.fileNotFound
        }
    }

    private nonisolated func requiredBaseBlobSize(
        for authorizedFile: WorkspaceChangesAuthorizedPathCache.AuthorizedFile
    ) throws -> Int64 {
        guard let blobSize = authorizedFile.baseBlobSize else {
            throw WorkspaceChangesServiceError.fileNotFound
        }
        return blobSize
    }

    private nonisolated func baseContentFingerprint(
        for authorizedFile: WorkspaceChangesAuthorizedPathCache.AuthorizedFile
    ) throws -> String {
        guard let blobOID = authorizedFile.baseBlobOID else {
            throw WorkspaceChangesServiceError.fileNotFound
        }
        return "blob:\(authorizedFile.snapshot.scope.diffBaseCommitOID):\(blobOID)"
    }
}
