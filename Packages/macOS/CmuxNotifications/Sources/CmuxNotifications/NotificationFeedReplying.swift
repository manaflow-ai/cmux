/// Routes feed notification decisions back into the feed domain.
@MainActor
public protocol NotificationFeedReplying: AnyObject {
    /// Delivers `decision` for the feed request identified by `requestId`.
    func deliverReply(requestId: String, decision: NotificationFeedDecision)

    /// Returns the permission capabilities for the feed request identified by
    /// `requestId`, or `nil` when the request is not present in the feed store.
    func permissionCapabilities(requestId: String) -> NotificationFeedPermissionCapabilities?

    /// Brings forward the agent surface for the workstream that raised a feed
    /// notification, the same jump the Feed card performs. Called when the user
    /// clicks the banner body.
    func openWorkstream(workstreamId: String)
}
