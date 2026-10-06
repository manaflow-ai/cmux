
/// `cloud-session-status`.

/// `cloud-session-status`.
public struct CloudSessionStatusRequest: DaemonRequest {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-status"
    public init() {}
}
