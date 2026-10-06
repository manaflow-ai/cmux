import Foundation

/// `cloud-session-clear`: ends the lease (sign-out, account switch).

/// `cloud-session-clear`: ends the lease (sign-out, account switch).
public struct CloudSessionClearRequest: DaemonRequest {
    public typealias Response = CloudSessionState
    public static let command = "cloud-session-clear"
    public init() {}
}
