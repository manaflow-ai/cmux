import Foundation

/// `feed-local-handoff-begin {item}` (the verified app connection only, else
/// `forbidden`): freezes an open item as `handing_off` before the app sends
/// `feed.adopt`.
public struct FeedLocalHandoffBeginRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var item: FeedLocalItem
    }
    public static let command = "feed-local-handoff-begin"
    public static let requiredCapability: String? = DaemonCapability.feedLocalOwner.rawValue
    public var item: String
    public init(item: String) { self.item = item }
}
