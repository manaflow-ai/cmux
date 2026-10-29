public import Foundation

public nonisolated enum BrowserFindDirection: Hashable, Sendable {
    case forward
    case backward
}

/// Result of a find-in-page step.
public nonisolated struct BrowserFindResult: Hashable, Sendable {
    public var matchFound: Bool
    /// Total matches when the engine can count them.
    public var matchCount: Int?
    /// 1-based index of the highlighted match when known.
    public var currentIndex: Int?

    public init(matchFound: Bool, matchCount: Int? = nil, currentIndex: Int? = nil) {
        self.matchFound = matchFound
        self.matchCount = matchCount
        self.currentIndex = currentIndex
    }

    public static let none = BrowserFindResult(matchFound: false, matchCount: 0)
}
