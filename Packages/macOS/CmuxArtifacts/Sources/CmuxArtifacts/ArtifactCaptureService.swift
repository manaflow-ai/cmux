public import Foundation

/// Applies project capture policy before importing detected agent artifacts.
public actor ArtifactCaptureService: ArtifactCapturing {
    private let store: any ArtifactStoring
    private let temporaryDirectory: URL

    /// Creates a capture service backed by a shared artifact store.
    ///
    /// - Parameters:
    ///   - store: Filesystem store used by automatic and manual capture.
    ///   - temporaryDirectory: Process temporary root used for ephemeral-path detection.
    public init(
        store: any ArtifactStoring,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.store = store
        self.temporaryDirectory = temporaryDirectory.standardizedFileURL
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
            guard isEligible(candidate, configuration: configuration) else {
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

    /// Explicitly adds one file through the same validated persistence path.
    ///
    /// - Parameters:
    ///   - sourceURL: Existing regular file to add.
    ///   - context: Project, workspace, and session grouping identity.
    ///   - capturedAt: Timestamp recorded in provenance.
    /// - Returns: Copy, deduplication, or already-stored result.
    public func add(
        sourceURL: URL,
        context: ArtifactCaptureContext,
        capturedAt: Date = .now
    ) async throws -> ArtifactImportOutcome {
        let configuration = await store.configuration(projectRoot: context.projectRoot)
        return try await store.importFile(
            sourceURL: sourceURL,
            context: context,
            provenance: .manual,
            configuration: configuration,
            capturedAt: capturedAt
        )
    }

    private func isEligible(
        _ candidate: ArtifactCandidate,
        configuration: ArtifactCaptureConfiguration
    ) -> Bool {
        switch candidate.provenance {
        case .created, .attached:
            return configuration.captureCreatedAndAttached
        case .referenced:
            return configuration.captureReferencedEphemeral
                && ArtifactPathResolver().isEphemeral(
                    candidate.sourceURL,
                    prefixes: configuration.ephemeralPathPrefixes,
                    temporaryDirectory: temporaryDirectory
                )
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
        case .pathOutsideStore:
            return .pathOutsideStore
        }
    }
}
