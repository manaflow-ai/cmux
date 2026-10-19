import Foundation

/// Coalesces concurrent watch-plan builds for one resolved repository.
actor GitMetadataWatchPlanCache {
    private var inFlightByRepository: [
        GitTrackedChangesSnapshotRepositoryKey: (
            token: UUID,
            task: Task<GitWorkspaceMetadataWatchDescriptor?, Never>
        )
    ] = [:]

    /// Runs one plan operation per repository at a time, sharing its result with
    /// callers that arrive while the bounded build is in flight.
    func plan(
        for repository: ResolvedGitRepository,
        operation: @escaping @Sendable () async -> GitWorkspaceMetadataWatchDescriptor?
    ) async -> GitWorkspaceMetadataWatchDescriptor? {
        let key = GitTrackedChangesSnapshotRepositoryKey(repository: repository)
        if let inFlight = inFlightByRepository[key] {
            return await inFlight.task.value
        }

        let token = UUID()
        let task = Task { await operation() }
        inFlightByRepository[key] = (token: token, task: task)
        let result = await task.value
        if inFlightByRepository[key]?.token == token {
            inFlightByRepository.removeValue(forKey: key)
        }
        return result
    }
}
