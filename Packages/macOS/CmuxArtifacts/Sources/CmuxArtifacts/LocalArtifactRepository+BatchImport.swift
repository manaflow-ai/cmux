public import Foundation

extension LocalArtifactRepository {
    /// Imports a capture batch with bounded Git preflight and one authoritative mutation phase.
    public func importFiles(
        candidates: [ArtifactCandidate],
        context: ArtifactCaptureContext,
        configuration: ArtifactCaptureConfiguration,
        maximumBatchBytes: Int64?,
        capturedAt: Date
    ) async -> [ArtifactImportAttempt] {
        guard !candidates.isEmpty else { return [] }
        let paths = ArtifactStorePaths(projectRoot: context.projectRoot)
        let sourcePathResolver = ArtifactPathResolver(fileManager: fileManager)
        do {
            try prepareForMutation(paths: paths)
        } catch let error as ArtifactStoreError {
            return candidates.map { _ in .rejected(error) }
        } catch {
            return candidates.map { _ in .rejected(.pathOutsideStore(paths.filesystemRoot.path)) }
        }
        var attempts = Array<ArtifactImportAttempt?>(repeating: nil, count: candidates.count)
        var preparedByIndex: [Int: PreparedArtifactImport] = [:]
        let stagingLease: ArtifactImportStagingLease
        do {
            stagingLease = try ArtifactImportStagingLease(
                root: paths.importStagingRoot,
                fileManager: fileManager
            )
        } catch {
            return candidates.map { _ in .rejected(.pathOutsideStore(paths.importStagingRoot.path)) }
        }
        defer { stagingLease.finish() }
        let expectedStagingDirectoryPath = stagingLease.directory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let stagedURLs = candidates.map { _ in stagingLease.makeStagedURL() }
        let candidateValidator = ArtifactGitIgnoreManager(fileManager: fileManager)
            .writeValidator(
                projectRoot: paths.projectRoot,
                commandRunner: gitCommandRunner
            )
        let privacyValidator: ArtifactGitPrivacyValidator?
        if let candidateValidator,
           await candidateValidator.storeIsUntracked(filesystemRoot: paths.filesystemRoot) {
            privacyValidator = candidateValidator
        } else {
            privacyValidator = nil
        }
        guard let privacyValidator,
              await privacyValidator.permits(destinations: stagedURLs) else {
            return candidates.map { _ in
                .rejected(.gitPrivacyUnavailable(paths.filesystemRoot.path))
            }
        }
        if Task.isCancelled {
            return finalizedAttempts(attempts, candidates: candidates)
        }
        let batchByteLimit = maximumBatchBytes.map { max(0, $0) }
        var stagedBytes: Int64 = 0
        candidateLoop: for (index, candidate) in candidates.enumerated() {
            guard attempts[index] == nil else { continue }
            if let batchByteLimit, stagedBytes >= batchByteLimit {
                for remainingIndex in index..<candidates.count {
                    attempts[remainingIndex] = .rejected(.batchByteLimitReached(
                        actual: 0,
                        limit: batchByteLimit
                    ))
                }
                break
            }
            let source = candidate.sourceURL.standardizedFileURL
            let stagedURL = stagedURLs[index]
            do {
                let remainingBytes = batchByteLimit.map { max(0, $0 - stagedBytes) }
                let snapshot = try ArtifactSourceSnapshotter(fileManager: fileManager).snapshot(
                    source: source,
                    paths: paths,
                    configuration: configuration,
                    maximumBytes: remainingBytes,
                    stagedURL: stagedURL,
                    expectedCanonicalPath: candidate.expectedCanonicalPath
                        ?? sourcePathResolver.canonicalPath(source),
                    stagingLease: stagingLease
                )
                stagedBytes += snapshot.size
                preparedByIndex[index] = PreparedArtifactImport(
                    candidate: ArtifactCandidate(
                        sourceURL: source,
                        provenance: candidate.provenance,
                        expectedCanonicalPath: candidate.expectedCanonicalPath
                    ),
                    snapshot: snapshot,
                    digest: try ArtifactDigestCalculator(fileManager: fileManager).digest(
                        url: snapshot.url,
                        expectedSize: snapshot.size,
                        allowedRoot: paths.importStagingRoot
                    )
                )
            } catch let error as ArtifactStoreError {
                if case .batchByteLimitReached(let actual, _) = error,
                   let batchByteLimit {
                    if stagedBytes == 0 {
                        attempts[index] = .rejected(.fileTooLarge(
                            actual: actual,
                            limit: batchByteLimit
                        ))
                    } else {
                        for remainingIndex in index..<candidates.count {
                            attempts[remainingIndex] = .rejected(.batchByteLimitReached(
                                actual: remainingIndex == index ? actual : 0,
                                limit: batchByteLimit
                            ))
                        }
                        break candidateLoop
                    }
                } else {
                    attempts[index] = .rejected(error)
                }
            } catch {
                attempts[index] = .rejected(.sourceNotRegularFile(source.path))
            }
        }
        defer {
            for prepared in preparedByIndex.values {
                try? fileManager.removeItem(at: prepared.snapshot.url)
            }
        }

        let orderedPrepared = preparedByIndex.sorted(by: { $0.key < $1.key })
        guard !orderedPrepared.isEmpty else {
            return finalizedAttempts(attempts, candidates: candidates)
        }
        let authorizedWritePlan: ArtifactWritePlan
        do {
            authorizedWritePlan = try makeConservativeWritePlan(
                prepared: orderedPrepared.map(\.value),
                context: context,
                paths: paths
            )
            guard await privacyValidator.permits(
                destinations: authorizedWritePlan.destinations
            ) else {
                for (index, _) in orderedPrepared {
                    attempts[index] = .rejected(
                        .gitPrivacyUnavailable(paths.filesystemRoot.path)
                    )
                }
                return finalizedAttempts(attempts, candidates: candidates)
            }
        } catch {
            let rejection = (error as? ArtifactStoreError)
                ?? ArtifactStoreError.pathOutsideStore(paths.filesystemRoot.path)
            for (index, _) in orderedPrepared {
                attempts[index] = .rejected(rejection)
            }
            return finalizedAttempts(attempts, candidates: candidates)
        }
        if Task.isCancelled {
            return finalizedAttempts(attempts, candidates: candidates)
        }

        let mutationLease: ArtifactStoreMutationLease
        do {
            mutationLease = try ArtifactStoreMutationLease(directory: paths.filesystemRoot)
        } catch let error as ArtifactStoreError {
            for (index, _) in orderedPrepared { attempts[index] = .rejected(error) }
            return finalizedAttempts(attempts, candidates: candidates)
        } catch {
            for (index, _) in orderedPrepared {
                attempts[index] = .rejected(.pathOutsideStore(paths.filesystemRoot.path))
            }
            return finalizedAttempts(attempts, candidates: candidates)
        }
        defer { mutationLease.finish() }

        var existingByDigest: [String: URL]
        do {
            existingByDigest = try buildDeduplicationIndex(
                prepared: orderedPrepared.map(\.value),
                paths: paths,
                configuration: configuration
            )
        } catch {
            let rejection = (error as? ArtifactStoreError)
                ?? ArtifactStoreError.pathOutsideStore(paths.filesystemRoot.path)
            for (index, _) in orderedPrepared { attempts[index] = .rejected(rejection) }
            return finalizedAttempts(attempts, candidates: candidates)
        }
        let writePlan: ArtifactWritePlan
        do {
            let refinedWritePlan = try makeWritePlan(
                prepared: orderedPrepared.map(\.value),
                existingByDigest: existingByDigest,
                context: context,
                paths: paths
            )
            guard authorizedWritePlan.authorizes(refinedWritePlan) else {
                for (index, _) in orderedPrepared {
                    attempts[index] = .rejected(.storeBusy(paths.filesystemRoot.path))
                }
                return finalizedAttempts(attempts, candidates: candidates)
            }
            writePlan = refinedWritePlan
        } catch {
            let rejection = (error as? ArtifactStoreError)
                ?? ArtifactStoreError.pathOutsideStore(paths.filesystemRoot.path)
            for (index, _) in orderedPrepared {
                attempts[index] = .rejected(rejection)
            }
            return finalizedAttempts(attempts, candidates: candidates)
        }

        var captureDirectory: URL?
        for (index, prepared) in orderedPrepared {
            guard !Task.isCancelled else { break }
            do {
                attempts[index] = .imported(try importPrepared(
                    prepared,
                    context: context,
                    paths: paths,
                    capturedAt: capturedAt,
                    existingByDigest: &existingByDigest,
                    captureDirectory: &captureDirectory,
                    mutationLease: mutationLease,
                    expectedSourceParentPath: expectedStagingDirectoryPath,
                    plannedDestination: writePlan.copyDestination(for: prepared),
                    plannedResolution: writePlan.captureResolution
                ))
            } catch let error as ArtifactStoreError {
                attempts[index] = .rejected(error)
            } catch {
                attempts[index] = .rejected(.sourceNotRegularFile(prepared.candidate.sourceURL.path))
            }
        }
        return finalizedAttempts(attempts, candidates: candidates)
    }

    private func buildDeduplicationIndex(
        prepared: [PreparedArtifactImport],
        paths: ArtifactStorePaths,
        configuration: ArtifactCaptureConfiguration
    ) throws -> [String: URL] {
        try ArtifactDeduplicationIndexBuilder(
            recorder: ArtifactProvenanceRecorder(
                fileManager: fileManager,
                encoder: encoder,
                decoder: decoder
            ),
            scanner: ArtifactDeduplicationScanner(
                fileManager: fileManager,
                maximumDepth: maximumScanDepth,
                nodeLimit: configuration.deduplicationScanNodeLimit,
                hashByteLimit: configuration.deduplicationHashByteLimit
            ),
            fileManager: fileManager
        ).build(prepared: prepared, paths: paths)
    }

    private func makeWritePlan(
        prepared: [PreparedArtifactImport],
        existingByDigest: [String: URL],
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths
    ) throws -> ArtifactWritePlan {
        try ArtifactWritePlanner(
            fileManager: fileManager,
            encoder: encoder,
            decoder: decoder,
            nodeBudget: nodeBudget
        ).plan(
            prepared: prepared,
            existingByDigest: existingByDigest,
            context: context,
            paths: paths
        )
    }

    private func makeConservativeWritePlan(
        prepared: [PreparedArtifactImport],
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths
    ) throws -> ArtifactWritePlan {
        try ArtifactWritePlanner(
            fileManager: fileManager,
            encoder: encoder,
            decoder: decoder,
            nodeBudget: nodeBudget
        ).conservativePlan(
            prepared: prepared,
            context: context,
            paths: paths
        )
    }

    private func finalizedAttempts(
        _ attempts: [ArtifactImportAttempt?],
        candidates: [ArtifactCandidate]
    ) -> [ArtifactImportAttempt] {
        attempts.enumerated().map { index, attempt in
            attempt ?? .rejected(.sourceNotRegularFile(candidates[index].sourceURL.path))
        }
    }
}
