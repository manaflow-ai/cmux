import Foundation

/// One item of the daemon's local feed owner (`feed-local-owner-v1`,
/// cmux-tui/spec/commands.md `feed-local-list`, plans/cmux-next/feed.md 9.1).
public struct FeedLocalItem: Decodable, Sendable, Hashable, Identifiable {
    /// Lifecycle of a local item (feed.md section 5 rule 3).
    public enum State: String, Codable, Sendable, Hashable {
        /// Owned by the daemon.
        case open
        /// Frozen while the app sends `feed.adopt`; reads refuse with `feed.moving`.
        case handingOff = "handing_off"
        /// Owned by `home`; this copy is never a write target.
        case moved
    }

    /// Where the item points in the daemon's tree (public ids).
    public struct Context: Decodable, Sendable, Hashable {
        public var workspace: String?
        public var tab: String?
        public var terminal: String?
        public init(workspace: String? = nil, tab: String? = nil, terminal: String? = nil) {
            self.workspace = workspace
            self.tab = tab
            self.terminal = terminal
        }
    }

    public var id: String
    public var dedupeKey: String
    public var title: String
    public var body: String
    public var level: String
    /// The producer: `cli`, `terminal`, `agent` (or `daemon`).
    public var source: String
    public var context: Context
    public var createdAtMs: UInt64
    public var updatedAtMs: UInt64
    public var readAtMs: UInt64?
    public var state: State
    public var home: String?
    public var count: UInt32

    public init(id: String, dedupeKey: String, title: String, body: String = "", level: String = "info",
                source: String = "agent", context: Context = .init(), createdAtMs: UInt64, updatedAtMs: UInt64? = nil,
                readAtMs: UInt64? = nil, state: State = .open, home: String? = nil, count: UInt32 = 1) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.title = title
        self.body = body
        self.level = level
        self.source = source
        self.context = context
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs ?? createdAtMs
        self.readAtMs = readAtMs
        self.state = state
        self.home = home
        self.count = count
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, level, source, context, state, home, count
        case dedupeKey = "dedupe_key"
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
        case readAtMs = "read_at_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        dedupeKey = try c.decode(String.self, forKey: .dedupeKey)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        level = try c.decodeIfPresent(String.self, forKey: .level) ?? "info"
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "cli"
        context = try c.decodeIfPresent(Context.self, forKey: .context) ?? .init()
        createdAtMs = try c.decode(UInt64.self, forKey: .createdAtMs)
        updatedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .updatedAtMs) ?? createdAtMs
        readAtMs = try c.decodeIfPresent(UInt64.self, forKey: .readAtMs)
        state = try c.decode(State.self, forKey: .state)
        home = try c.decodeIfPresent(String.self, forKey: .home)
        count = try c.decodeIfPresent(UInt32.self, forKey: .count) ?? 1
    }

    public var isUnread: Bool { readAtMs == nil }
}

/// `feed-local-list {state?, terminal_id?, unread?}`: local items, oldest first.
public struct FeedLocalListRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var items: [FeedLocalItem]
    }
    public static let command = "feed-local-list"
    public var state: FeedLocalItem.State?
    public var terminalId: String?
    public var unread: Bool?
    public init(state: FeedLocalItem.State? = nil, terminalId: String? = nil, unread: Bool? = nil) {
        self.state = state
        self.terminalId = terminalId
        self.unread = unread
    }
}
