import CmuxFoundation
import Foundation

extension FileContentChangeCoordinator {
    typealias WatchRegistration = (
        watcher: FileWatcher?,
        task: Task<Void, Never>?
    )

    typealias Observation = (
        canonicalPath: String,
        watchedPath: String
    )

    /// Private storage for one canonical path; it has no independent lifecycle
    /// or consumer, so keeping it with the coordinator preserves its ownership
    /// boundary instead of introducing another app-target service.
    struct Entry {
        /// Fingerprints are tracked per watched path because an alias can be
        /// retargeted while a panel opened through the real path remains valid.
        var lastObservedStates: [String: FilePreviewFileState] = [:]
        var watches: [String: WatchRegistration] = [:]
        var lookupPathsByWatchedPath: [String: Set<String>] = [:]
        var indexedLookupPaths: Set<String> = []
        var observers: [UUID: ChangeHandler] = [:]
    }
}
