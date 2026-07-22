import CmuxAgentChat
import CmuxArtifacts
import Foundation

/// Bridges transcript artifact snapshots into the project-local artifact store.
actor AgentArtifactCaptureCoordinator {
    private let captureService: ArtifactCaptureService
    private let fileManager: FileManager
    private var completedRevisionBySession: [String: UInt64] = [:]
    private var inFlightRevisionBySession: [String: UInt64] = [:]
    private var completedCheckpointBySession: [String: AgentArtifactCaptureCheckpoint] = [:]

    init(
        captureService: ArtifactCaptureService,
        fileManager: FileManager = .default
    ) {
        self.captureService = captureService
        self.fileManager = fileManager
    }

    func maximumTranscriptScanBytes(for record: AgentChatSessionRecord) async -> UInt64? {
        guard let projectRoot = projectRoot(for: record) else { return nil }
        return await captureService.automaticTranscriptScanByteLimit(projectRoot: projectRoot)
    }

    func capture(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot
    ) async {
        guard !Task.isCancelled,
              let projectRoot = projectRoot(for: record),
              completedRevisionBySession[record.sessionID].map({ snapshot.revision > $0 }) ?? true,
              inFlightRevisionBySession[record.sessionID].map({ snapshot.revision > $0 }) ?? true else {
            return
        }
        inFlightRevisionBySession[record.sessionID] = snapshot.revision
        defer {
            if inFlightRevisionBySession[record.sessionID] == snapshot.revision {
                inFlightRevisionBySession.removeValue(forKey: record.sessionID)
            }
        }

        let checkpoint = completedCheckpointBySession[record.sessionID]
        let transcriptReset = checkpoint.map {
            $0.transcriptLineage != snapshot.transcriptLineage
                || snapshot.lineCount < $0.lineCount
        } ?? false
        let completedCursor = transcriptReset ? nil : checkpoint?.referenceCursor
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
            completedCheckpointBySession[record.sessionID] = AgentArtifactCaptureCheckpoint(
                transcriptLineage: snapshot.transcriptLineage,
                lineCount: snapshot.lineCount,
                referenceCursor: completedCursor
            )
            completedRevisionBySession[record.sessionID] = snapshot.revision
            return
        }
        let outcomes = await captureService.capture(
            candidates: pending.map {
                ArtifactCandidate(
                    sourceURL: URL(fileURLWithPath: $0.path),
                    provenance: artifactProvenance($0.provenance)
                )
            },
            context: context
        )
        guard !Task.isCancelled,
              inFlightRevisionBySession[record.sessionID] == snapshot.revision else {
            return
        }
        let processedCount = outcomes.prefix { !isRetryableBlocker($0) }.count
        if processedCount > 0 {
            let last = pending[processedCount - 1]
            completedCheckpointBySession[record.sessionID] = AgentArtifactCaptureCheckpoint(
                transcriptLineage: snapshot.transcriptLineage,
                lineCount: snapshot.lineCount,
                referenceCursor: AgentArtifactReferenceCursor(
                    sequence: last.lastReferencedSeq,
                    path: last.path
                )
            )
        }
        if processedCount == pending.count {
            completedRevisionBySession[record.sessionID] = snapshot.revision
        }
    }

    func save(
        record: AgentChatSessionRecord,
        sourceURL: URL,
        capturedAt: Date = .now
    ) async throws -> ChatArtifactSaveResult {
        guard let projectRoot = projectRoot(for: record) else {
            throw AgentArtifactCaptureSaveError.missingWorkingDirectory
        }
        let outcome = try await captureService.add(
            sourceURL: sourceURL,
            context: ArtifactCaptureContext(
                projectRoot: projectRoot,
                workspaceID: record.workspaceID,
                sessionID: record.sessionID,
                agentName: record.agentKind.sourceName
            ),
            capturedAt: capturedAt
        )
        guard let importedRecord = outcome.record else {
            throw AgentArtifactCaptureSaveError.rejected
        }
        let path = ArtifactStorePaths(projectRoot: projectRoot).artifactsRoot
            .appendingPathComponent(importedRecord.relativePath, isDirectory: false)
        return ChatArtifactSaveResult(
            path: path.path,
            relativePath: importedRecord.relativePath,
            reference: ".cmux/artifacts/\(importedRecord.relativePath)"
        )
    }

    /// Releases transcript progress when the owning chat session disappears.
    func removeSession(sessionID: String) {
        completedRevisionBySession.removeValue(forKey: sessionID)
        inFlightRevisionBySession.removeValue(forKey: sessionID)
        completedCheckpointBySession.removeValue(forKey: sessionID)
    }

    private func projectRoot(for record: AgentChatSessionRecord) -> URL? {
        guard let workingDirectory = record.workingDirectory,
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

    private func isRetryableBlocker(_ outcome: ArtifactImportOutcome) -> Bool {
        switch outcome {
        case .skipped(.candidateLimitReached), .skipped(.gitPrivacyUnavailable):
            return true
        case .copied, .deduplicated, .alreadyStored, .skipped:
            return false
        }
    }
}
