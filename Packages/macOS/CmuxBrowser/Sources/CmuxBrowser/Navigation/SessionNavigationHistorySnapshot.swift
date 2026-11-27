public import Foundation

/// The back/forward URL strings captured for session persistence.
///
/// `backHistoryURLStrings` is ordered oldest-first (the same order WebKit's
/// `backForwardList.backList` uses); `forwardHistoryURLStrings` is ordered
/// nearest-forward-first. Restoring these via
/// `RestoredSessionHistory.restore(backHistoryURLStrings:forwardHistoryURLStrings:currentURLString:)`
/// reproduces the traversal state.
public struct SessionNavigationHistorySnapshot: Sendable, Equatable {
    /// Back-list URLs, oldest first.
    public var backHistoryURLStrings: [String]

    /// Forward-list URLs, nearest-forward first.
    public var forwardHistoryURLStrings: [String]

    /// Creates a snapshot.
    public init(backHistoryURLStrings: [String], forwardHistoryURLStrings: [String]) {
        self.backHistoryURLStrings = backHistoryURLStrings
        self.forwardHistoryURLStrings = forwardHistoryURLStrings
    }
}
