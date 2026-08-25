import CmuxAgentChat
import CmuxArtifacts
import Foundation

/// Bridges transcript artifact snapshots into the project-local artifact store.
actor AgentArtifactCaptureCoordinator {
    private static let retainedSessionLimit = 64
    private static let maximumContentionRetryCount = 3
    private let captureService: ArtifactCaptureService
    private let fileManager: FileManager
    private let contentionRetryDelay: @Sendable (Int) async throws -> Void
    private var inFlightRevisionBySession: [String: UInt64] = [:]
    private var completedStateBySession = ChatArtifactLRUCache<String, AgentArtifactCompletedCaptureState>(
        capacity: retainedSessionLimit
    )

    init(
        captureService: ArtifactCaptureService,
        fileManager: FileManager = .default,
        contentionRetryDelay: @escaping @Sendable (Int) async throws -> Void = { attempt in
            let milliseconds = 50 * (1 << min(max(attempt, 0), 3))
            // A bounded, cancellable backoff is the intended store-contention behavior.
            try await Task<Never, Never>.sleep(for: .milliseconds(milliseconds))
        }
    ) {
        self.captureService = captureService
        self.fileManager = fileManager
        self.contentionRetryDelay = contentionRetryDelay
    }

    func maximumTranscriptScanBytes(for record: AgentChatSessionRecord) async -> UInt64? {
        guard let projectRoot = projectRoot(for: record) else { return nil }
        return await captureService.automaticTranscriptScanByteLimit(projectRoot: projectRoot)
    }

    @discardableResult
    func capture(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot
    ) async -> AgentArtifactCaptureProgress {
        let completedState = completedStateBySession.value(forKey: record.sessionID)
        guard !Task.isCancelled else { return .blocked }
        guard let projectRoot = projectRoot(for: record),
              completedState.flatMap(\.revision).map({ snapshot.revision > $0 }) ?? true else {
            return .complete
        }
        guard inFlightRevisionBySession[record.sessionID]
            .map({ snapshot.revision > $0 }) ?? true else {
            return .blocked
        }
        inFlightRevisionBySession[record.sessionID] = snapshot.revision
        defer {
            if inFlightRevisionBySession[record.sessionID] == snapshot.revision {
                inFlightRevisionBySession.removeValue(forKey: record.sessionID)
            }
        }

        let checkpoint = completedState?.checkpoint
        let sameExtentRewrite = checkpoint.map {
            !$0.transcriptGeneration.isEmpty
                && $0.transcriptGeneration != snapshot.generation
                && $0.transcriptExtent == snapshot.transcriptExtent
        } ?? false
        let transcriptReset = (checkpoint.map {
            $0.transcriptLineage != snapshot.transcriptLineage
                || snapshot.transcriptExtent < $0.transcriptExtent
        } ?? false) || sameExtentRewrite
        let completedCursor = transcriptReset ? nil : checkpoint?.referenceCursor
        let currentPaths = Set(snapshot.artifacts.map(\.path))
        // Reference order can differ from authorization order, so consume authority per path.
        var processedAuthorizationSequenceByPath: [String: Int] = transcriptReset
            ? [:]
            : checkpoint?.processedAuthorizationSequenceByPath.filter {
                currentPaths.contains($0.key)
            } ?? [:]
        var seenPaths: Set<String> = []
        let pending = snapshot.artifacts
            .filter { artifact in
                let cursor = AgentArtifactReferenceCursor(
                    sequence: artifact.lastReferencedSeq,
                    path: artifact.path
                )
                return (completedCursor.map { cursor > $0 } ?? true)
                    && seenPaths.insert(artifact.path).inserted
            }
            .sorted {
                AgentArtifactReferenceCursor(sequence: $0.lastReferencedSeq, path: $0.path)
                    < AgentArtifactReferenceCursor(sequence: $1.lastReferencedSeq, path: $1.path)
            }
        let context = ArtifactCaptureContext(
            projectRoot: projectRoot,
            workspaceID: record.workspaceID,
            sessionID: record.sessionID,
            agentName: record.agentKind.sourceName
        )
        guard !pending.isEmpty else {
            completedStateBySession.insert(
                AgentArtifactCompletedCaptureState(
                    revision: snapshot.revision,
                    checkpoint: AgentArtifactCaptureCheckpoint(
                        transcriptGeneration: snapshot.generation,
                        transcriptLineage: snapshot.transcriptLineage,
                        transcriptExtent: snapshot.transcriptExtent,
                        referenceCursor: completedCursor,
                        processedAuthorizationSequenceByPath: processedAuthorizationSequenceByPath
                    )
                ),
                forKey: record.sessionID
            )
            return .complete
        }
        let outcomes = await captureService.capture(
            candidates: pending.map {
                ArtifactCandidate(
                    sourceURL: URL(fileURLWithPath: $0.path),
                    provenance: artifactProvenance(
                        captureProvenance(
                            for: $0,
                            processedAuthorizationSequenceByPath: processedAuthorizationSequenceByPath
                        )
                    )
                )
            },
            context: context
        )
        guard !Task.isCancelled,
              inFlightRevisionBySession[record.sessionID] == snapshot.revision else {
            return .blocked
        }
        let processedCount = outcomes.prefix { !isRetryableBlocker($0) }.count
        var updatedCheckpoint = checkpoint
        if processedCount > 0 {
            for artifact in pending.prefix(processedCount) {
                guard let authorization = freshAuthorization(
                    for: artifact,
                    processedAuthorizationSequenceByPath: processedAuthorizationSequenceByPath
                ) else { continue }
                processedAuthorizationSequenceByPath[artifact.path] = authorization.sequence
            }
            let last = pending[processedCount - 1]
            updatedCheckpoint = AgentArtifactCaptureCheckpoint(
                transcriptGeneration: snapshot.generation,
                transcriptLineage: snapshot.transcriptLineage,
                transcriptExtent: snapshot.transcriptExtent,
                referenceCursor: AgentArtifactReferenceCursor(
                    sequence: last.lastReferencedSeq,
                    path: last.path
                ),
                processedAuthorizationSequenceByPath: processedAuthorizationSequenceByPath
            )
        }
        if processedCount > 0 {
            completedStateBySession.insert(
                AgentArtifactCompletedCaptureState(
                    revision: processedCount == pending.count
                        ? snapshot.revision
                        : completedState?.revision,
                    checkpoint: updatedCheckpoint
                ),
                forKey: record.sessionID
            )
        }
        guard processedCount < pending.count,
              outcomes.indices.contains(processedCount) else {
            return processedCount == pending.count ? .complete : .blocked
        }
        switch outcomes[processedCount] {
        case .skipped(.candidateLimitReached):
            return .needsContinuation
        case .skipped(.storeBusy):
            return .retryableContention
        case .copied, .deduplicated, .alreadyStored, .skipped:
            return .blocked
        }
    }

    func waitForContentionRetry(afterAttempt attempt: Int) async -> Bool {
        guard attempt < Self.maximumContentionRetryCount, !Task.isCancelled else {
            return false
        }
        do {
            try await contentionRetryDelay(attempt)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    func save(
        context: ArtifactCaptureContext,
        sourceURL: URL,
        expectedCanonicalPath: String,
        capturedAt: Date = .now
    ) async throws -> ChatArtifactSaveResult {
        let outcome = try await captureService.add(
            sourceURL: sourceURL,
            context: context,
            expectedCanonicalPath: expectedCanonicalPath,
            capturedAt: capturedAt
        )
        guard let importedRecord = outcome.record else {
            throw AgentArtifactCaptureSaveError.rejected
        }
        let path = ArtifactStorePaths(projectRoot: context.projectRoot).filesystemRoot
            .appendingPathComponent(importedRecord.relativePath, isDirectory: false)
        return ChatArtifactSaveResult(
            path: path.path,
            relativePath: importedRecord.relativePath,
            reference: ".cmux/\(importedRecord.relativePath)"
        )
    }

    /// Releases transcript progress when the owning chat session disappears.
    func removeSession(sessionID: String) {
        inFlightRevisionBySession.removeValue(forKey: sessionID)
        _ = completedStateBySession.removeValue(forKey: sessionID)
    }

    func captureContext(for record: AgentChatSessionRecord) -> ArtifactCaptureContext? {
        guard let projectRoot = projectRoot(for: record) else { return nil }
        return ArtifactCaptureContext(
            projectRoot: projectRoot,
            workspaceID: record.workspaceID,
            sessionID: record.sessionID,
            agentName: record.agentKind.sourceName
        )
    }

    private func projectRoot(for record: AgentChatSessionRecord) -> URL? {
        guard record.workingDirectoryAuthority.authorizesArtifactPersistence,
              let workingDirectory = record.workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ArtifactProjectLocator().projectRoot(
            startingAt: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            fileManager: fileManager
        )
    }

    private func artifactProvenance(_ provenance: ChatArtifactProvenance) -> ArtifactProvenance {
        switch provenance {
        case .created: return .created
        case .attached: return .attached
        case .referenced: return .referenced
        }
    }

    private func captureProvenance(
        for artifact: ChatArtifactIndexedReference,
        processedAuthorizationSequenceByPath: [String: Int]
    ) -> ChatArtifactProvenance {
        freshAuthorization(
            for: artifact,
            processedAuthorizationSequenceByPath: processedAuthorizationSequenceByPath
        )?.provenance ?? .referenced
    }

    private func freshAuthorization(
        for artifact: ChatArtifactIndexedReference,
        processedAuthorizationSequenceByPath: [String: Int]
    ) -> ChatArtifactCaptureAuthorization? {
        guard let authorization = artifact.captureAuthorization,
              authorization.sequence
                > (processedAuthorizationSequenceByPath[artifact.path] ?? Int.min) else {
            return nil
        }
        return authorization
    }

    private func isRetryableBlocker(_ outcome: ArtifactImportOutcome) -> Bool {
        switch outcome {
        case .skipped(.candidateLimitReached), .skipped(.gitPrivacyUnavailable), .skipped(.storeBusy):
            return true
        case .copied, .deduplicated, .alreadyStored, .skipped:
            return false
        }
    }
}
