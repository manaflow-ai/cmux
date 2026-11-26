import Foundation

/// Identifies the persistent SSH session that owns a remote resume binding.
struct SurfaceResumeRemoteContext: Codable, Equatable, Hashable, Sendable {
    let workspaceID: UUID
    let surfaceID: UUID
    let persistentPTYSessionID: String

    func retargeted(
        workspaceID: UUID,
        surfaceID: UUID,
        persistentPTYSessionID: String
    ) -> SurfaceResumeRemoteContext {
        SurfaceResumeRemoteContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            persistentPTYSessionID: persistentPTYSessionID
        )
    }

    func matches(
        workspaceID: UUID,
        surfaceID: UUID,
        persistentPTYSessionID: String
    ) -> Bool {
        guard self.workspaceID == workspaceID,
              self.surfaceID == surfaceID,
              let storedSessionID = normalizedSessionID(self.persistentPTYSessionID),
              let candidateSessionID = normalizedSessionID(persistentPTYSessionID) else {
            return false
        }
        return storedSessionID == candidateSessionID
    }

    private func normalizedSessionID(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
