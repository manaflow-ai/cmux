import Foundation

/// Coalesces concurrent watch-plan builds for one resolved repository.
actor GitMetadataWatchPlanCache {
    private var inFlightByRepository: [GitTrackedChangesSnapshotRepositoryKey: (token: UUID, task: Task<GitWorkspaceMetadataWatchDescriptor?, Never>)] = [:]

    /// Shares one bounded descriptor build with concurrent callers for a repository.
    func plan(for repository: ResolvedGitRepository, operation: @escaping @Sendable () async -> GitWorkspaceMetadataWatchDescriptor?) async -> GitWorkspaceMetadataWatchDescriptor? {
        let key = GitTrackedChangesSnapshotRepositoryKey(repository: repository)
        if let inFlight = inFlightByRepository[key] { return await inFlight.task.value }
        let token = UUID()
        let task = Task { await operation() }
        inFlightByRepository[key] = (token, task)
        let result = await task.value
        if inFlightByRepository[key]?.token == token { inFlightByRepository.removeValue(forKey: key) }
        return result
    }
}
