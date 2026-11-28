import Foundation

/// `cloud-requests-list` data, newest first.
public struct CloudMessageRequests: Decodable, Sendable, Equatable {
    public var requests: [CloudMessageRequest]
    public init(requests: [CloudMessageRequest]) { self.requests = requests }
}
