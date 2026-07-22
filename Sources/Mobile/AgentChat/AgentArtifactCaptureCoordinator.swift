import CmuxAgentChat
import CmuxArtifacts
import Foundation

/// Bridges transcript artifact snapshots into the project-local artifact store.
actor AgentArtifactCaptureCoordinator {
    private let captureService: ArtifactCaptureService
    private let fileManager: FileManager
    private var completedRevisionBySession: [String: UInt64] = [:]
    private var inFlightRevisionBySession: [String: UInt64] = [:]
    private var completedReferenceCursorBySession: [String: AgentArtifactReferenceCursor] = [:]

    init(
        captureService: ArtifactCaptureService,
        fileManager: FileManager = .default
    ) {
        self.captureService = captureService
        self.fileManager = fileManager
    }

    func capture(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot
    ) async {
        guard !Task.isCancelled,
              let workingDirectory = record.workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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

        let workingDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let projectRoot = ArtifactProjectLocator().projectRoot(
            startingAt: workingDirectoryURL,
            fileManager: fileManager
        )
        let completedCursor = completedReferenceCursorBySession[record.sessionID]
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
        let processedCount = outcomes.prefix {
            $0 != .skipped(.candidateLimitReached)
        }.count
        if processedCount > 0 {
            let last = pending[processedCount - 1]
            completedReferenceCursorBySession[record.sessionID] = AgentArtifactReferenceCursor(
                sequence: last.lastReferencedSeq,
                path: last.path
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
        guard let workingDirectory = record.workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentArtifactCaptureSaveError.missingWorkingDirectory
        }
        let projectRoot = ArtifactProjectLocator().projectRoot(
            startingAt: URL(fileURLWithPath: workingDirectory, isDirectory: true),
            fileManager: fileManager
        )
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

    private func artifactProvenance(_ provenance: ChatArtifactProvenance) -> ArtifactProvenance {
        switch provenance {
        case .created: return .created
        case .attached: return .attached
        case .referenced: return .referenced
        }
    }
}
