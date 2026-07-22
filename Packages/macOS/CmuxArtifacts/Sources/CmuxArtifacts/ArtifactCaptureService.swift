public import Foundation

/// Applies project capture policy before importing detected agent artifacts.
public actor ArtifactCaptureService: ArtifactCapturing {
    private let store: any ArtifactStoring

    /// Creates a capture service backed by a shared artifact store.
    ///
    /// - Parameter store: Filesystem store used by automatic and manual capture.
    public init(store: any ArtifactStoring) {
        self.store = store
    }

    /// Returns the transcript budget when automatic capture is enabled.
    ///
    /// - Parameter projectRoot: Canonical project root containing `.cmux`.
    /// - Returns: Normalized byte limit, or `nil` when automatic capture is disabled.
    public func automaticTranscriptScanByteLimit(projectRoot: URL) async -> UInt64? {
        let configuration = await store.configuration(projectRoot: projectRoot)
        guard configuration.automaticCaptureEnabled else { return nil }
        return UInt64(configuration.maximumTranscriptScanBytes)
    }

    /// Captures eligible detected paths using the project's effective policy.
    ///
    /// Duplicate path detections in one scan are folded together and the
    /// configured candidate limit is applied before any file reads occur.
    ///
    /// - Parameters:
    ///   - candidates: Paths emitted by an agent artifact detector.
    ///   - context: Project, workspace, and session grouping identity.
    ///   - capturedAt: Timestamp recorded for accepted paths.
    /// - Returns: One observable outcome for every distinct candidate.
    public func capture(
        candidates: [ArtifactCandidate],
        context: ArtifactCaptureContext,
        capturedAt: Date = .now
    ) async -> [ArtifactImportOutcome] {
        let configuration = await store.configuration(projectRoot: context.projectRoot)
        let distinctCandidates = distinct(candidates)
        guard configuration.automaticCaptureEnabled else {
            return distinctCandidates.map { _ in .skipped(.automaticCaptureDisabled) }
        }

        var outcomes = Array<ArtifactImportOutcome?>(repeating: nil, count: distinctCandidates.count)
        var importCandidates: [ArtifactCandidate] = []
        var importIndices: [Int] = []
        for (index, candidate) in distinctCandidates.enumerated() {
            guard index < configuration.maximumFilesPerCapture else {
                outcomes[index] = .skipped(.candidateLimitReached)
                continue
            }
            guard isEligible(candidate, context: context, configuration: configuration) else {
                outcomes[index] = .skipped(.provenanceNotEligible)
                continue
            }
            importCandidates.append(candidate)
            importIndices.append(index)
        }
        let attempts = await store.importFiles(
            candidates: importCandidates,
            context: context,
            configuration: configuration,
            capturedAt: capturedAt
        )
        for (index, attempt) in zip(importIndices, attempts) {
            switch attempt {
            case .imported(let outcome):
                outcomes[index] = outcome
            case .rejected(let error):
                outcomes[index] = .skipped(error.skipReason)
            }
        }
        return outcomes.map { $0 ?? .skipped(.notARegularFile) }
    }

    /// Explicitly adds files through the same validated persistence path.
    ///
    /// Large user selections are split into policy-sized persistence batches so
    /// each batch shares one bounded deduplication scan without exceeding the
    /// project's automatic-capture work limit.
    ///
    /// - Parameters:
    ///   - sourceURLs: Existing regular files to add.
    ///   - context: Project, workspace, and session grouping identity.
    ///   - capturedAt: Timestamp recorded in provenance.
    /// - Returns: One import attempt per source URL, preserving input order.
    public func add(
        sourceURLs: [URL],
        context: ArtifactCaptureContext,
        capturedAt: Date = .now
    ) async -> [ArtifactImportAttempt] {
        guard !sourceURLs.isEmpty else { return [] }
        let configuration = await store.configuration(projectRoot: context.projectRoot).normalized
        let batchSize = configuration.maximumFilesPerCapture
        var attempts: [ArtifactImportAttempt] = []
        attempts.reserveCapacity(sourceURLs.count)
        var batchStart = sourceURLs.startIndex
        while batchStart < sourceURLs.endIndex {
            let batchEnd = sourceURLs.index(
                batchStart,
                offsetBy: batchSize,
                limitedBy: sourceURLs.endIndex
            ) ?? sourceURLs.endIndex
            let candidates = sourceURLs[batchStart..<batchEnd].map {
                ArtifactCandidate(sourceURL: $0, provenance: .manual)
            }
            attempts.append(contentsOf: await store.importFiles(
                candidates: candidates,
                context: context,
                configuration: configuration,
                capturedAt: capturedAt
            ))
            batchStart = batchEnd
        }
        return attempts
    }

    private func isEligible(
        _ candidate: ArtifactCandidate,
        context: ArtifactCaptureContext,
        configuration: ArtifactCaptureConfiguration
    ) -> Bool {
        switch candidate.provenance {
        case .created, .attached:
            return configuration.captureCreatedAndAttached
        case .referenced:
            return configuration.captureReferencedEphemeral
                && ArtifactPathResolver().relativePath(
                    candidate.sourceURL,
                    root: context.projectRoot
                ) != nil
        case .manual:
            return true
        }
    }

    private func distinct(_ candidates: [ArtifactCandidate]) -> [ArtifactCandidate] {
        var paths: Set<String> = []
        return candidates.filter {
            paths.insert($0.sourceURL.standardizedFileURL.path).inserted
        }
    }
}

private extension ArtifactStoreError {
    var skipReason: ArtifactSkipReason {
        switch self {
        case .sourceNotRegularFile:
            return .notARegularFile
        case .unsupportedExtension:
            return .unsupportedExtension
        case .fileTooLarge:
            return .exceedsSizeLimit
        case .artifactNotFound, .ambiguousArtifactName:
            return .notARegularFile
        case .scanIncomplete:
            return .candidateLimitReached
        case .pathOutsideStore:
            return .pathOutsideStore
        case .corruptProvenance:
            return .corruptProvenance
        case .gitPrivacyUnavailable:
            return .gitPrivacyUnavailable
        case .storeBusy:
            return .storeBusy
        }
    }
}
