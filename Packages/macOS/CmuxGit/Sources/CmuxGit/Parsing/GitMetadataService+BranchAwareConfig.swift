import Foundation

extension GitMetadataService {
    /// Adds branch-aware config paths to the legacy watch plan.
    nonisolated func branchAwareWatchDescriptor(
        _ descriptor: GitWorkspaceMetadataWatchDescriptor,
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext
    ) -> GitWorkspaceMetadataWatchDescriptor {
        let configPaths = GitConfigBranchTraversal(
            repository: repository,
            branchContext: branchContext
        ).configURLs().map { $0.standardizedFileURL.path }
        let metadataPaths = sortedUniqueMetadataPaths(
            descriptor.gitMetadataPaths + configPaths
        )
        let existingConfigPaths = configPaths.filter {
            fileStatusReader.status(atPath: $0) != nil
        }
        let watchedPaths = sortedUniqueMetadataPaths(
            descriptor.watchedPaths + existingConfigPaths
        )
        return GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: descriptor.repositoryRoot,
            watchedPaths: watchedPaths,
            gitMetadataPaths: metadataPaths,
            trackedEntryPaths: descriptor.trackedEntryPaths,
            acceptsAllWorkTreeEvents: descriptor.acceptsAllWorkTreeEvents,
            eventCoalescingInterval: descriptor.eventCoalescingInterval,
            eventFilterIdentity: descriptor.eventFilterIdentity,
            degradation: descriptor.degradation
        )
    }

    private nonisolated func sortedUniqueMetadataPaths(_ paths: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for path in paths {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result.sorted()
    }
}
