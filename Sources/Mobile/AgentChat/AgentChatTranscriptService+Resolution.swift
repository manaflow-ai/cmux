import Foundation

extension AgentChatTranscriptService {
    /// Resolves one session transcript off the main actor and persists a successful fallback.
    func resolvedTranscript(
        sessionID: String
    ) async throws -> (record: AgentChatSessionRecord, path: String)? {
        guard var candidate = registry.record(sessionID: sessionID) else { return nil }
        let resolver = self.resolver

        for _ in 0..<2 {
            let resolutionRecord = candidate
            let candidateTranscriptPath = candidate.transcriptPath
            let candidateAgentKind = candidate.agentKind
            let candidateWorkspaceID = candidate.workspaceID
            let candidateSurfaceID = candidate.surfaceID
            let candidateWorkingDirectory = candidate.workingDirectory
            let candidateHookStoreSessionID = candidate.hookStoreLookupSessionID
            let resolvedPath: String?
            if let boundedPath = resolver.boundedTranscriptPath(for: resolutionRecord) {
                resolvedPath = boundedPath
            } else {
                resolvedPath = await fallbackResolutionCoordinator.resolve(for: resolutionRecord)
            }
            guard let resolvedPath,
                  let current = registry.record(sessionID: sessionID) else {
                return nil
            }
            guard current.transcriptPath == candidateTranscriptPath,
                  current.agentKind == candidateAgentKind,
                  current.workspaceID == candidateWorkspaceID,
                  current.surfaceID == candidateSurfaceID,
                  current.workingDirectory == candidateWorkingDirectory,
                  current.hookStoreLookupSessionID == candidateHookStoreSessionID else {
                candidate = current
                continue
            }
            if current.transcriptPath != resolvedPath {
                registry.update(sessionID: sessionID) { $0.transcriptPath = resolvedPath }
            }
            guard let persisted = registry.record(sessionID: sessionID) else { return nil }
            return (persisted, resolvedPath)
        }
        return nil
    }

    /// Retries user-requested history resolution without caching cancellation as a miss.
    func resolvedTranscriptRecordForHistory(sessionID: String) async -> AgentChatSessionRecord? {
        failedResolutions.remove(sessionID)
        do {
            guard let resolved = try await resolvedTranscript(sessionID: sessionID) else {
                failedResolutions.insert(sessionID)
                return nil
            }
            return resolved.record
        } catch is CancellationError {
            return nil
        } catch {
            failedResolutions.insert(sessionID)
            return nil
        }
    }
}
