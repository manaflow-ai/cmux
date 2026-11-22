import Foundation
import WebKit

extension BrowserScriptWorld {
    var contentWorld: WKContentWorld {
        switch self {
        case .page: .page
        case .isolated: .defaultClient
        }
    }
}

/// Tracks the "3 of 12" position, which WebKit's find API does not report.
/// It assumes each step moves one match, which holds unless the page changes
/// or the user clicks elsewhere between steps.
nonisolated struct FindState: Sendable {
    private var query: String?
    private var index = 0

    mutating func step(query newQuery: String, direction: BrowserFindDirection, matchFound: Bool, count: Int?) -> BrowserFindResult {
        guard matchFound else {
            query = newQuery
            index = 0
            return BrowserFindResult(matchFound: false, matchCount: count ?? 0, currentIndex: nil)
        }
        guard let count, count > 0 else {
            query = newQuery
            return BrowserFindResult(matchFound: true, matchCount: nil, currentIndex: nil)
        }
        if query != newQuery {
            index = direction == .forward ? 1 : count
        } else {
            switch direction {
            case .forward: index = index >= count ? 1 : index + 1
            case .backward: index = index <= 1 ? count : index - 1
            }
        }
        query = newQuery
        return BrowserFindResult(matchFound: true, matchCount: count, currentIndex: index)
    }
}
