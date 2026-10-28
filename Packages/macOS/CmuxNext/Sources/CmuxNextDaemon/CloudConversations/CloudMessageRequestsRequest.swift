import Foundation

/// `cloud-requests-list`: the account's open message requests (the Worker's `home.requests.list`,
/// plans/cmux-next/home-messaging-invites/DESIGN.md 2.3): invites from people the user is not
/// connected to, for the verified email the app's lease is for. Answered with
/// `CloudConversationOp.acceptRequest` or `.dismissRequest(block:)`.
public struct CloudMessageRequestsRequest: DaemonRequest {
    public typealias Response = CloudMessageRequests
    public static let command = "cloud-requests-list"
    public init() {}
}

/// `cloud-requests-list` data, newest first.
public struct CloudMessageRequests: Decodable, Sendable, Equatable {
    public var requests: [CloudMessageRequest]
    public init(requests: [CloudMessageRequest]) { self.requests = requests }
}
