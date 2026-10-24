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
        /// The entry's document came from a form submission (a POST): a
        /// restore, a duplicate or a wake never sends it again without the
        /// person (BR-R1). Absent when false.
        public var formPost: Bool?

        public init(url: String, title: String? = nil, scrollY: Double? = nil, formPost: Bool? = nil) {
            self.url = url
            self.title = title
            self.scrollY = scrollY
            self.formPost = formPost
        }
        // Snake case both ways: requests encode snake case, replies decode as is.
        enum CodingKeys: String, CodingKey {
            case url, title
            case scrollY = "scroll_y"
            case formPost = "form_post"
        }
    }

    /// The page engine's own saved history (WebKit's interactionState,
    /// base64, or the Chromium fork's navigation state), so a relaunch
    /// rebuilds the engine's back list and scroll position. Only this Mac's
    /// daemon keeps it; nil when it would not fit.
    public struct EngineState: Codable, Sendable, Equatable {
        /// "webkit-2" or "chromium-2" (`BrowserHistoryWriter`; older tags are not restored).
        public var engine: String
        public var data: String

        public init(engine: String, data: String) {
            self.engine = engine
            self.data = data
        }
    }

    public var entries: [Entry]
    public var index: Int
    public var engineState: EngineState?

    public init(entries: [Entry], index: Int, engineState: EngineState? = nil) {
        self.entries = entries
        self.index = index
        self.engineState = engineState
    }

    enum CodingKeys: String, CodingKey {
        case entries, index
        case engineState = "engine_state"
    }

    /// Bytes the stored object may take with its engine state: under the
    /// daemon's 64 KiB limit, measured as this app encodes it (which
    /// escapes more than the daemon, so the daemon's copy is smaller).
    public static let maxStoredBytes = 60 * 1024

    /// This history with `state`, or without any engine state when the
    /// two would not fit in `maxStoredBytes`.
    public func with(engineState state: EngineState?, maxStoredBytes: Int = Self.maxStoredBytes) -> Self {
        var history = self
        history.engineState = state
        guard state != nil, let encoded = try? JSONEncoder().encode(history), encoded.count <= maxStoredBytes else {
            history.engineState = nil
            return history
        }
        return history
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
        guard maxEntries > 0, let current = entries[checked: index] else { return nil }
        var start = index, end = index
        var bytes = current.byteCount
        // Grow one entry at a time toward the nearer side.
        while end - start + 1 < maxEntries {
            let back = start > 0 ? start - 1 : nil
            let forward = end < entries.count - 1 ? end + 1 : nil
            // The nearer entry that fits; on a tie, the back one.
            let fitting = [back, forward].compactMap(\.self).filter { candidate in
                entries[checked: candidate].map { bytes + $0.byteCount <= maxBytes } ?? false
            }
            guard let next = fitting.min(by: { (($0 - index).magnitude, $0) < (($1 - index).magnitude, $1) }) else { break }
            bytes += entries[checked: next]?.byteCount ?? 0
            if next < start { start = next } else { end = next }
        }
        return FrontendBrowserHistory(entries: Array(entries.dropFirst(start).prefix(end - start + 1)), index: index - start,
                                      engineState: engineState)
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
    public static let requiredCapability: String? = DaemonCapability.frontendBrowserHistory.rawValue
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
    public static let requiredCapability: String? = DaemonCapability.frontendBrowserHistory.rawValue
    public var surface: SurfaceID

    public init(surface: SurfaceID) {
        self.surface = surface
    }
}
