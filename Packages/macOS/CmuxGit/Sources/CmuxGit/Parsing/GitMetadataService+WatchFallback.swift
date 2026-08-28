import Darwin
import Foundation

extension GitMetadataService {
    /// Keeps a conservative root watcher when an index format cannot be parsed.
    nonisolated func applyingForcedWorkTreeRoots(
        _ descriptor: GitWorkspaceMetadataWatchDescriptor,
        repositories: Set<String>
    ) -> GitWorkspaceMetadataWatchDescriptor {
        guard !repositories.isEmpty else { return descriptor }
        let existingRoots = repositories.filter { isDirectory(atPath: $0) }
        guard !existingRoots.isEmpty else { return descriptor }

        var watchedPaths = Set(descriptor.watchedPaths)
        for root in existingRoots {
            watchedPaths.insert(root)
        }
        let rootIsForced = existingRoots.contains(descriptor.repositoryRoot)
        let anyForcedRoot = !existingRoots.isEmpty
        return GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: descriptor.repositoryRoot,
            watchedPaths: watchedPaths.sorted(),
            gitMetadataPaths: descriptor.gitMetadataPaths,
            metadataSentinelPaths: descriptor.metadataSentinelPaths,
            trackedEntryPaths: rootIsForced ? [] : descriptor.trackedEntryPaths,
            forcedWorkTreeRoots: existingRoots.sorted(),
            acceptsAllWorkTreeEvents: rootIsForced || descriptor.acceptsAllWorkTreeEvents,
            eventCoalescingInterval: rootIsForced
                ? safetyConfiguration.unfilteredWorkTreeEventThrottle
                : descriptor.eventCoalescingInterval,
            eventFilterIdentity: rootIsForced ? nil : descriptor.eventFilterIdentity,
            degradation: anyForcedRoot
                ? .unreadableIndex
                : descriptor.degradation
        )
    }

    private nonisolated func isDirectory(atPath path: String) -> Bool {
        var metadata = stat()
        return path.withCString { Darwin.stat($0, &metadata) == 0 }
            && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }
}
