
/// `cloud-inbox-unsubscribe`.

/// `cloud-inbox-unsubscribe`.
public struct CloudInboxUnsubscribeRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "cloud-inbox-unsubscribe"
    public init() {}
}
