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
            let resolvedPath = try await Task.detached(priority: .utility) {
                try resolver.transcriptPath(for: resolutionRecord)
            }.value
            guard let resolvedPath,
                  let current = registry.record(sessionID: sessionID) else {
                return nil
            }
            guard current.transcriptPath == candidateTranscriptPath else {
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
