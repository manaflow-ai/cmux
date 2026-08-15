import Foundation

/// A notification that a directory's git state may have changed, published by
/// ``SidebarGitMetadataService`` for the git diff panel.
///
/// The panel subscribes via ``SidebarGitMetadataService/diffInvalidations()``
/// and refreshes its diff when it receives an event for the directory it is
/// showing. Events are coalesced per directory: a burst of filesystem changes
/// in one watcher window yields a single event.
public struct WorkspaceGitInvalidationEvent: Sendable, Equatable {
    /// The directory whose git state may have changed.
    public let directory: String

    /// Creates an invalidation event for `directory`.
    ///
    /// - Parameter directory: The directory whose git state may have changed.
    public init(directory: String) {
        self.directory = directory
    }
}
