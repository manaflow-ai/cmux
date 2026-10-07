import Foundation

// `cloud-conversations-v1` commands (plans/cmux-next/home-cloud-proxy.md
// section 4). The daemon only transports: ConversationDO owns each cloud
// conversation and UserDO owns the inbox. Trusted local connections only.

/// `cloud-inbox-subscribe`: the daemon's shared inbox socket for this connection.
public struct CloudInboxSubscribeRequest: DaemonRequest {
    public typealias Response = CloudSubscription
    public static let command = "cloud-inbox-subscribe"
    public init() {}
}

/// `cloud-inbox-unsubscribe`.
public struct CloudInboxUnsubscribeRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "cloud-inbox-unsubscribe"
    public init() {}
}
