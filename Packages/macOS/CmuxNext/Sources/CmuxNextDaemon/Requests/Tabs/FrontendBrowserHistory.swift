import Foundation

/// A frontend browser tab's session history (`frontend-browser-history-v1`):
/// its back/forward entries, oldest first, the current one, and where each
/// was scrolled. The daemon stores it as an opaque object outside the
/// journal; the app restores it when the tab's page is made again.
public struct FrontendBrowserHistory: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var url: String
        public var title: String?
        public var scrollY: Double?

        public init(url: String, title: String? = nil, scrollY: Double? = nil) {
            self.url = url
            self.title = title
            self.scrollY = scrollY
        }
        // Snake case both ways: requests encode snake case, replies decode as is.
        enum CodingKeys: String, CodingKey {
            case url, title
            case scrollY = "scroll_y"
        }
    }

    public var entries: [Entry]
    public var index: Int

    public init(entries: [Entry], index: Int) {
        self.entries = entries
        self.index = index
    }

    /// Entries kept per tab, nearest the current one first.
    public static let maxEntries = 25

    /// At most `maxEntries`, keeping the current entry and those nearest
    /// it (back entries first); `index` stays on the current entry. Nil
    /// when there is nothing to keep or the index is out of range.
    public func bounded(maxEntries: Int = Self.maxEntries) -> Self? {
        guard entries.indices.contains(index), maxEntries > 0 else { return nil }
        guard entries.count > maxEntries else { return self }
        let back = min(index, maxEntries - 1)
        let forward = min(entries.count - 1 - index, maxEntries - 1 - back)
        let start = index - min(index, maxEntries - 1 - forward)
        let kept = Array(entries[start...(index + forward)])
        return FrontendBrowserHistory(entries: kept, index: index - start)
    }
}

/// Stores (or with nil, clears) a frontend browser tab's session history.
public struct SetFrontendBrowserHistoryRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-frontend-browser-history"
    public var surface: SurfaceID
    public var history: FrontendBrowserHistory?

    public init(surface: SurfaceID, history: FrontendBrowserHistory?) {
        self.surface = surface
        self.history = history
    }

    enum CodingKeys: String, CodingKey { case surface, history }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(surface, forKey: .surface)
        // An explicit null clears it.
        try c.encode(history, forKey: .history)
    }
}

/// A frontend browser tab's stored session history, nil when none.
public struct GetFrontendBrowserHistoryRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var history: FrontendBrowserHistory?
    }
    public static let command = "get-frontend-browser-history"
    public var surface: SurfaceID

    public init(surface: SurfaceID) {
        self.surface = surface
    }
}
