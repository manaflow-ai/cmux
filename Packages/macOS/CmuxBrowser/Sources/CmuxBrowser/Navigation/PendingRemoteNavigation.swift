public import Foundation

/// A navigation deferred until a remote-workspace proxy endpoint becomes available.
///
/// When a surface backed by a remote-workspace proxy is asked to navigate before
/// its proxy endpoint exists, the request is parked here and replayed once the
/// endpoint arrives or the pane reverts to local rendering.
public struct PendingRemoteNavigation: Sendable {
    /// The deferred request to replay.
    public let request: URLRequest
    /// Whether replaying should record a typed-navigation history entry.
    public let recordTypedNavigation: Bool
    /// Whether replaying should preserve restored session history.
    public let preserveRestoredSessionHistory: Bool

    /// Creates a deferred navigation.
    public init(request: URLRequest, recordTypedNavigation: Bool, preserveRestoredSessionHistory: Bool) {
        self.request = request
        self.recordTypedNavigation = recordTypedNavigation
        self.preserveRestoredSessionHistory = preserveRestoredSessionHistory
    }
}
