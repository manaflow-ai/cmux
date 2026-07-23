public import Foundation

extension LocalArtifactRepository {
    /// Imports a capture batch with bounded Git preflight and one authoritative mutation phase.
    public func importFiles(
        candidates: [ArtifactCandidate],
        context: ArtifactCaptureContext,
        configuration: ArtifactCaptureConfiguration,
        capturedAt: Date
    ) async -> [ArtifactImportAttempt] {
        guard !candidates.isEmpty else { return [] }
        let paths = ArtifactStorePaths(projectRoot: context.projectRoot)
        do {
            try prepare(paths: paths)
        } catch let error as ArtifactStoreError {
            return candidates.map { _ in .rejected(error) }
        } catch {
            return candidates.map { _ in .rejected(.pathOutsideStore(paths.filesystemRoot.path)) }
        }
        var attempts = Array<ArtifactImportAttempt?>(repeating: nil, count: candidates.count)
        var preparedByIndex: [Int: PreparedArtifactImport] = [:]
        let stagingLease: ArtifactImportStagingLease
        do {
            stagingLease = try ArtifactImportStagingLease.acquire(
                root: paths.importStagingRoot,
                fileManager: fileManager
            )
        } catch {
            return candidates.map { _ in .rejected(.pathOutsideStore(paths.importStagingRoot.path)) }
        }
        defer { stagingLease.finish() }
        let stagedURLs = candidates.map { _ in stagingLease.makeStagedURL() }
        let automaticIndices = candidates.indices.filter { candidates[$0].provenance != .manual }
        var privacyValidator: ArtifactGitPrivacyValidator?
        if !automaticIndices.isEmpty {
            let candidateValidator = ArtifactGitIgnoreManager(fileManager: fileManager)
                .automaticWriteValidator(
                    projectRoot: paths.projectRoot,
                    commandRunner: gitCommandRunner
                )
            if let candidateValidator,
               await candidateValidator.storeIsUntracked(filesystemRoot: paths.filesystemRoot) {
                privacyValidator = candidateValidator
            }
            let stagingDestinations = automaticIndices.map { stagedURLs[$0] }
            let permitsStaging = if let privacyValidator {
                await privacyValidator.permits(destinations: stagingDestinations)
            } else {
                false
            }
            if !permitsStaging {
                for index in automaticIndices {
                    attempts[index] = .rejected(.gitPrivacyUnavailable(paths.filesystemRoot.path))
                }
                privacyValidator = nil
            }
            if Task.isCancelled {
                return finalizedAttempts(attempts, candidates: candidates)
            }
        }
        for (index, candidate) in candidates.enumerated() {
            guard attempts[index] == nil else { continue }
            let source = candidate.sourceURL.standardizedFileURL
            let stagedURL = stagedURLs[index]
            do {
                let snapshot = try ArtifactSourceSnapshotter(fileManager: fileManager).snapshot(
                    source: source,
                    paths: paths,
                    configuration: configuration,
                    stagedURL: stagedURL
                )
                preparedByIndex[index] = PreparedArtifactImport(
                    candidate: ArtifactCandidate(sourceURL: source, provenance: candidate.provenance),
                    snapshot: snapshot,
                    digest: try ArtifactDigestCalculator().digest(url: snapshot.url)
                )
            } catch let error as ArtifactStoreError {
                attempts[index] = .rejected(error)
            } catch {
                attempts[index] = .rejected(.sourceNotRegularFile(source.path))
            }
        }
        defer {
            for prepared in preparedByIndex.values {
                try? fileManager.removeItem(at: prepared.snapshot.url)
            }
        }

        var orderedPrepared = preparedByIndex.sorted(by: { $0.key < $1.key })
        var authorizedAutomaticPlan: ArtifactAutomaticWritePlan?
        let automaticPrepared = orderedPrepared.filter { $0.value.candidate.provenance != .manual }
        if !automaticPrepared.isEmpty {
            do {
                let preflightIndex = try buildDeduplicationIndex(
                    prepared: orderedPrepared.map(\.value),
                    paths: paths,
                    configuration: configuration
                )
                let plan = try makeAutomaticWritePlan(
                    prepared: automaticPrepared.map(\.value),
                    existingByDigest: preflightIndex,
                    context: context,
                    paths: paths
                )
                if let privacyValidator,
                   await privacyValidator.permits(destinations: plan.destinations) {
                    authorizedAutomaticPlan = plan
                } else {
                    for (index, _) in automaticPrepared {
                        attempts[index] = .rejected(.gitPrivacyUnavailable(paths.filesystemRoot.path))
                    }
                    orderedPrepared.removeAll { $0.value.candidate.provenance != .manual }
                }
            } catch {
                let rejection = (error as? ArtifactStoreError)
                    ?? ArtifactStoreError.pathOutsideStore(paths.filesystemRoot.path)
                for index in preparedByIndex.keys {
                    attempts[index] = .rejected(rejection)
                }
                return finalizedAttempts(attempts, candidates: candidates)
            }
            if Task.isCancelled {
                return finalizedAttempts(attempts, candidates: candidates)
            }
        }
        guard !orderedPrepared.isEmpty else {
            return finalizedAttempts(attempts, candidates: candidates)
        }

        let mutationLease: ArtifactStoreMutationLease
        do {
            mutationLease = try ArtifactStoreMutationLease.acquire(directory: paths.filesystemRoot)
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
        var automaticWritePlan: ArtifactAutomaticWritePlan?
        let refreshedAutomatic = orderedPrepared.filter { $0.value.candidate.provenance != .manual }
        if !refreshedAutomatic.isEmpty {
            do {
                let refreshedPlan = try makeAutomaticWritePlan(
                    prepared: refreshedAutomatic.map(\.value),
                    existingByDigest: existingByDigest,
                    context: context,
                    paths: paths
                )
                if authorizedAutomaticPlan?.authorizes(refreshedPlan) == true {
                    automaticWritePlan = refreshedPlan
                } else {
                    for (index, _) in refreshedAutomatic {
                        attempts[index] = .rejected(.storeBusy(paths.filesystemRoot.path))
                    }
                    orderedPrepared.removeAll { $0.value.candidate.provenance != .manual }
                }
            } catch {
                let rejection = (error as? ArtifactStoreError)
                    ?? ArtifactStoreError.pathOutsideStore(paths.filesystemRoot.path)
                for (index, _) in refreshedAutomatic {
                    attempts[index] = .rejected(rejection)
                }
                orderedPrepared.removeAll { $0.value.candidate.provenance != .manual }
            }
        }

        var captureDirectory: URL?
        for (index, prepared) in orderedPrepared {
            do {
                attempts[index] = .imported(try importPrepared(
                    prepared,
                    context: context,
                    paths: paths,
                    capturedAt: capturedAt,
                    existingByDigest: &existingByDigest,
                    captureDirectory: &captureDirectory,
                    plannedDestination: automaticWritePlan?.copyDestination(for: prepared),
                    plannedResolution: automaticWritePlan?.captureResolution
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
            )
        ).build(prepared: prepared, paths: paths)
    }

    private func makeAutomaticWritePlan(
        prepared: [PreparedArtifactImport],
        existingByDigest: [String: URL],
        context: ArtifactCaptureContext,
        paths: ArtifactStorePaths
    ) throws -> ArtifactAutomaticWritePlan {
        try ArtifactAutomaticWritePlanner(
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

    private func finalizedAttempts(
        _ attempts: [ArtifactImportAttempt?],
        candidates: [ArtifactCandidate]
    ) -> [ArtifactImportAttempt] {
        attempts.enumerated().map { index, attempt in
            attempt ?? .rejected(.sourceNotRegularFile(candidates[index].sourceURL.path))
        }
    }
}
