import Foundation
internal import CmuxFoundation
internal import CmuxGit

/// Lock-backed snapshot used from the watcher's utility executor to reject
/// ignored/untracked event batches before they arm the debounce or wake the
/// main actor. Descriptor replacement is rare (an index/metadata change).
final class WorkspaceGitMetadataEventRelevanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [GitWorkspaceMetadataWatchDescriptor]

    init(descriptors: [GitWorkspaceMetadataWatchDescriptor]) {
        self.descriptors = descriptors
    }

    func replaceDescriptors(_ descriptors: [GitWorkspaceMetadataWatchDescriptor]) {
        lock.lock()
        self.descriptors = descriptors
        lock.unlock()
    }

    func containsRelevantChange(_ change: RecursivePathChange) -> Bool {
        lock.lock()
        let snapshot = descriptors
        lock.unlock()
        return snapshot.contains { descriptor in
            descriptor.containsRelevantChange(
                paths: change.paths,
                requiresFullRescan: change.requiresFullRescan
            )
        }
    }
}
