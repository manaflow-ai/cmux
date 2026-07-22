import CmuxAgentChat
import CmuxArtifacts
import Foundation

/// Bridges transcript artifact snapshots into the project-local artifact store.
actor AgentArtifactCaptureCoordinator {
    private let captureService: ArtifactCaptureService
    private let fileManager: FileManager
    private var completedGenerationBySession: [String: String] = [:]
    private var inFlightGenerationBySession: [String: String] = [:]

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
              !snapshot.artifacts.isEmpty,
              let workingDirectory = record.workingDirectory,
              !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              completedGenerationBySession[record.sessionID] != snapshot.generation,
              inFlightGenerationBySession[record.sessionID] != snapshot.generation else {
            return
        }
        inFlightGenerationBySession[record.sessionID] = snapshot.generation
        defer {
            if inFlightGenerationBySession[record.sessionID] == snapshot.generation {
                inFlightGenerationBySession.removeValue(forKey: record.sessionID)
            }
        }

        let workingDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let projectRoot = ArtifactProjectLocator().projectRoot(
            startingAt: workingDirectoryURL,
            fileManager: fileManager
        )
        var seenPaths: Set<String> = []
        var pending = snapshot.artifacts.compactMap { artifact -> ArtifactCandidate? in
            guard seenPaths.insert(artifact.path).inserted else { return nil }
            return ArtifactCandidate(
                sourceURL: URL(fileURLWithPath: artifact.path),
                provenance: artifactProvenance(artifact.provenance)
            )
        }
        let context = ArtifactCaptureContext(
            projectRoot: projectRoot,
            workspaceID: record.workspaceID,
            sessionID: record.sessionID,
            agentName: record.agentKind.sourceName
        )
        while !pending.isEmpty {
            guard !Task.isCancelled else { return }
            let outcomes = await captureService.capture(
                candidates: pending,
                context: context
            )
            let backlog = zip(pending, outcomes).compactMap { candidate, outcome in
                outcome == .skipped(.candidateLimitReached) ? candidate : nil
            }
            guard backlog.count < pending.count else { return }
            pending = backlog
            await Task.yield()
        }
        guard !Task.isCancelled else { return }
        completedGenerationBySession[record.sessionID] = snapshot.generation
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
