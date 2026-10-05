public import Foundation
import Synchronization

/// A source of omnibar rows (`browser.omnibar.sources` in cmux.json). The
/// order of the enabled sources breaks score ties.
public nonisolated enum OmniboxSource: String, Hashable, Sendable, CaseIterable {
    case history
    /// Open tabs of the same browser profile ("Switch to Tab").
    case tabs
    case bookmarks
    /// Remote search suggestions from the search engine's suggest endpoint.
    case search
    /// Arithmetic answers (opt-in).
    case calculator

    /// `["history", "tabs", "bookmarks", "search"]`.
    public static let defaultOrder: [OmniboxSource] = [.history, .tabs, .bookmarks, .search]
}

/// An open browser tab offered as a "Switch to Tab" row.
public nonisolated struct OmniboxTabRow: Hashable, Sendable {
    /// The tab's id, for revealing it.
    public var key: String
    public var url: URL
    public var title: String?

    public init(key: String, url: URL, title: String?) {
        self.key = key
        self.url = url
        self.title = title
    }
}

/// The newest query generation of one omnibar. The controller moves it on
/// every reducer step; work for any other generation stops at its next
/// check (phase A returns nothing, phase B never delivers).
public nonisolated final class OmniboxGenerationGate: Sendable {
    private let latest = Atomic<UInt64>(0)

    public init() {}

    public func begin(_ generation: UInt64) {
        latest.store(generation, ordering: .relaxed)
    }

    public func isCurrent(_ generation: UInt64) -> Bool {
        latest.load(ordering: .relaxed) == generation
    }
}
