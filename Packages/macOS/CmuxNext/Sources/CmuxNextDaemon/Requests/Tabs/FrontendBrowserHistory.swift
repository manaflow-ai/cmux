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
    /// Bytes of URLs and titles kept per tab, well under the daemon's
    /// 64 KiB limit on the stored object.
    public static let maxBytes = 48 * 1024

    /// At most `maxEntries` and about `maxBytes`, keeping the current entry
    /// and those nearest it (back on a tie); `index` stays on the
    /// current entry. Nil when there is nothing to keep or the index is out
    /// of range.
    public func bounded(maxEntries: Int = Self.maxEntries, maxBytes: Int = Self.maxBytes) -> Self? {
        guard entries.indices.contains(index), maxEntries > 0 else { return nil }
        var start = index, end = index
        var bytes = entries[index].byteCount
        // Grow one entry at a time toward the nearer side.
        while end - start + 1 < maxEntries {
            let back = start > 0 ? start - 1 : nil
            let forward = end < entries.count - 1 ? end + 1 : nil
            // The nearer entry that fits; on a tie, the back one.
            let fitting = [back, forward].compactMap(\.self).filter { bytes + entries[$0].byteCount <= maxBytes }
            guard let next = fitting.min(by: { (($0 - index).magnitude, $0) < (($1 - index).magnitude, $1) }) else { break }
            bytes += entries[next].byteCount
            if next < start { start = next } else { end = next }
        }
        return FrontendBrowserHistory(entries: Array(entries[start...end]), index: index - start)
    }
}

extension FrontendBrowserHistory.Entry {
    /// About how many bytes the entry takes in the stored object.
    var byteCount: Int { url.utf8.count + (title?.utf8.count ?? 0) + 48 }
}

/// Stores (or with nil, clears) a frontend browser tab's session history.
public struct SetFrontendBrowserHistoryRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-frontend-browser-history"
    public static let requiredCapability: String? = DaemonCapabilities.shared.frontendBrowserHistory
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
    public static let requiredCapability: String? = DaemonCapabilities.shared.frontendBrowserHistory
    public var surface: SurfaceID

    public init(surface: SurfaceID) {
        self.surface = surface
    }
}
