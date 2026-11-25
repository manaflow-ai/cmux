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

/// `feed-local-handoff-abort {item}` (the verified app connection only): the
/// cloud owner answered `feed.adopt.cancel` with `cancelled: true`, so the
/// item is open here again. Never on a timeout or a lost reply.
public struct FeedLocalHandoffAbortRequest: DaemonRequest {
    public typealias Response = FeedLocalHandoffBeginRequest.Response
    public static let command = "feed-local-handoff-abort"
    public static let requiredCapability: String? = DaemonCapability.feedLocalOwner.rawValue
    public var item: String
    public init(item: String) { self.item = item }
}

/// `feed-local-handoff-done {item, home}` (the verified app connection only):
/// the new owner committed the item; it becomes `moved`.
public struct FeedLocalHandoffDoneRequest: DaemonRequest {
    public typealias Response = FeedLocalHandoffBeginRequest.Response
    public static let command = "feed-local-handoff-done"
    public static let requiredCapability: String? = DaemonCapability.feedLocalOwner.rawValue
    public var item: String
    public var home: String
    public init(item: String, home: String) {
        self.item = item
        self.home = home
    }
}
