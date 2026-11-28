import Foundation

extension FeedLocalHandoffBeginRequest {
    /// Also the `feed-local-handoff-abort` and `feed-local-handoff-done` result.
    public struct Response: Decodable, Sendable, Equatable {
        public var item: FeedLocalItem
    }
}
