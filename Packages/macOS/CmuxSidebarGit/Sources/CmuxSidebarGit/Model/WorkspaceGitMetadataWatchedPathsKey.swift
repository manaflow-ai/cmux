import Foundation

/// Identifies one shared filesystem watcher by its normalized watched paths.
struct WorkspaceGitMetadataWatchedPathsKey: Equatable, Hashable, Sendable {
    let paths: [String]
    let eventFilterIdentity: String?
    let eventCoalescingInterval: Duration

    init(
        paths: [String],
        eventFilterIdentity: String? = nil,
        eventCoalescingInterval: Duration = .milliseconds(250)
    ) {
        self.paths = Array(Set(paths)).sorted()
        self.eventFilterIdentity = eventFilterIdentity
        self.eventCoalescingInterval = eventCoalescingInterval
    }
}
