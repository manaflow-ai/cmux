import Foundation

/// `feed-local-handoff-begin {item}` (trusted local only): freezes an open
/// item as `handing_off` before the app sends `feed.adopt`.
public struct FeedLocalHandoffBeginRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var item: FeedLocalItem
    }
    public static let command = "feed-local-handoff-begin"
    public var item: String
    public init(item: String) { self.item = item }
}

/// `feed-local-handoff-done {item, home}` (trusted local only): the new owner
/// committed the item; it becomes `moved`.
public struct FeedLocalHandoffDoneRequest: DaemonRequest {
    public typealias Response = FeedLocalHandoffBeginRequest.Response
    public static let command = "feed-local-handoff-done"
    public var item: String
    public var home: String
    public init(item: String, home: String) {
        self.item = item
        self.home = home
    }
}
