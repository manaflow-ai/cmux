
/// `cloud-inbox-subscribe`: the daemon's shared inbox socket for this connection.

/// `cloud-inbox-subscribe`: the daemon's shared inbox socket for this connection.
public struct CloudInboxSubscribeRequest: DaemonRequest {
    public typealias Response = CloudSubscription
    public static let command = "cloud-inbox-subscribe"
    public init() {}
}
