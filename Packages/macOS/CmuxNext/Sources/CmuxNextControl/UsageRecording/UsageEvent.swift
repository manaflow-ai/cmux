public import CmuxNextActions
public import CmuxNextDaemon
import Foundation

/// One event of opt-in usage recording, in the vocabulary of cmux-tui/crates/cmux-usage/src/event.rs
/// (serde tag `t`, snake_case fields; a field it does not know refuses the whole batch). Shape only:
/// every field is a number, a flag, a closed name or an id the daemon hashes before it writes.
/// The app maps and sends; the Rust report aggregates.
///
/// ```swift
/// let line = UsageRecord(at: 1_762_500_000_000, event: .active(on: true))  // {"at":…,"ev":{"t":"active","on":true}}
/// ```
enum UsageEvent: Sendable, Equatable {
    /// The app started: its channel, build number and how the previous run ended
    /// (`clean`, `crash`, `hang` or `unknown`).
    case launch(channel: String, build: String, prev: String)
    /// The app became active or stopped being active.
    case active(on: Bool)
    /// The keyboard moved to `surface`, in content tab `tab` (a raw tab id; the daemon hashes it).
    case focus(surface: UsageSurface, tab: String?)
    /// An action ran: its report id (``ActionReportNaming``), its entrypoint
    /// (``ActionEntrypoint/rawValue``) and its perform-to-commit time.
    case action(id: String, via: String, ms: Double)
    /// How much is open now.
    case counts(UsageCounts)

    /// The event for one timed action run: the report id, so a cmux.json command's own name never
    /// leaves (`custom`), and the commit time of a committed run. A run that did not end at its
    /// commit (a missed commit, a nested menu loop) still counts as a use, with 0 ms: its time is
    /// not the action's work.
    static func run(_ sample: ActionTimingSample, naming: ActionReportNaming) -> UsageEvent {
        .action(id: naming.reportID(for: sample.id), via: sample.entrypoint.rawValue,
                ms: sample.outcome == .committed ? sample.milliseconds : 0)
    }
}

/// Where the keyboard is, folded to what a report needs (`Surface` in event.rs).
enum UsageSurface: String, Sendable, Equatable, Encodable {
    case terminal, browser, chat, page, conversation, sidebar, palette, overlay, other

    /// The surface of the key window's shown focus by its stable name (`FocusState.Resolved.kind`);
    /// nil (a top page such as Settings or History covers the workspace) is a page.
    init(kind: String?) {
        switch kind {
        case nil, "page": self = .page
        case "terminal": self = .terminal
        case "browserPage", "addressBar", "findBar", "devTools": self = .browser
        case "agentPage": self = .chat
        case "conversation": self = .conversation
        case "sidebar", "sidebarField": self = .sidebar
        case "overlay:palette": self = .palette
        case let kind? where kind.hasPrefix("overlay:"): self = .overlay
        default: self = .other
        }
    }
}

/// How much is open (`Counts` in event.rs): plain counts, no names.
public struct UsageCounts: Sendable, Equatable, Encodable {
    public var windows = 0
    public var workspaces = 0
    public var screens = 0
    public var panes = 0
    public var tabs = 0
    public var terminals = 0
    public var browsers = 0
    public var chats = 0
    /// The most panes one screen holds (the size of a split layout).
    public var maxPanesPerScreen = 0
    /// The key window's sidebar width in points, 0 when hidden.
    public var sidebarWidth = 0

    enum CodingKeys: String, CodingKey {
        case windows, workspaces, screens, panes, tabs, terminals, browsers, chats
        case maxPanesPerScreen = "max_panes_per_screen"
        case sidebarWidth = "sidebar_width"
    }

    /// Nothing open.
    public init() {}

    /// What `workspaces` hold, by screen, pane and tab kind: an O(workspaces) walk, made only at
    /// the switch-on, on resigning active and at quit (``UsageRecorder``).
    ///
    /// - Parameters:
    ///   - workspaces: The local daemon's workspaces.
    ///   - windows: Open windows.
    ///   - sidebarWidth: The key window's sidebar width in points, 0 when hidden.
    ///   - isChat: Whether a tab id is an agent chat.
    @MainActor
    public init(workspaces: [WorkspaceModel], windows: Int, sidebarWidth: Int, isChat: @MainActor (String) -> Bool) {
        self.windows = windows
        self.workspaces = workspaces.count
        self.sidebarWidth = sidebarWidth
        for screen in workspaces.lazy.flatMap(\.screens) {
            screens += 1
            panes += screen.panes.count
            maxPanesPerScreen = max(maxPanesPerScreen, screen.panes.count)
            for tab in screen.panes.lazy.flatMap(\.tabs) {
                tabs += 1
                if isChat(tab.id) {
                    chats += 1
                    continue
                }
                switch tab.kind {
                case .pty, .remoteTerminal: terminals += 1
                case .browser: browsers += 1
                default: break
                }
            }
        }
    }
}

/// One line of a `usage-record` batch: `{"at": <unix ms>, "ev": {"t": …}}`.
struct UsageRecord: Sendable, Equatable, Encodable {
    /// Unix time in milliseconds.
    var at: Int64
    var event: UsageEvent

    enum CodingKeys: String, CodingKey {
        case at
        case event = "ev"
    }

    /// Now, in unix milliseconds.
    static func nowMilliseconds() -> Int64 { Int64(exactly: (Date().timeIntervalSince1970 * 1000).rounded()) ?? 0 }

    /// The records of a batch of action runs, each stamped with its start: `nowUptimeNanos`
    /// (``ActionBudgetMonitor/now()``, the runs' clock) is `nowMilliseconds` in unix time.
    ///
    /// - Parameters:
    ///   - samples: The runs, as the action budget reporter hands them over.
    ///   - naming: The report id of each action.
    ///   - nowUptimeNanos: The runs' clock now.
    ///   - nowMilliseconds: Unix milliseconds now.
    /// - Returns: One action record per run.
    static func actions(_ samples: [ActionTimingSample], naming: ActionReportNaming, nowUptimeNanos: UInt64,
                        nowMilliseconds: Int64) -> [UsageRecord] {
        samples.map { sample in
            let agoNanos = nowUptimeNanos >= sample.startUptimeNanos ? nowUptimeNanos - sample.startUptimeNanos : 0
            return UsageRecord(at: nowMilliseconds - Int64(clamping: agoNanos / 1_000_000), event: .run(sample, naming: naming))
        }
    }

    /// The `usage-record` events text of `records`: a JSON array.
    static func batch(_ records: [UsageRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(records), as: UTF8.self)
    }
}

extension UsageEvent: Encodable {
    private enum Key: String, CodingKey {
        case t, channel, build, prev, on, surface, tab, id, via, ms
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .launch(channel, build, prev):
            try container.encode("launch", forKey: .t)
            try container.encode(channel, forKey: .channel)
            try container.encode(build, forKey: .build)
            try container.encode(prev, forKey: .prev)
        case let .active(on):
            try container.encode("active", forKey: .t)
            try container.encode(on, forKey: .on)
        case let .focus(surface, tab):
            try container.encode("focus", forKey: .t)
            try container.encode(surface, forKey: .surface)
            try container.encodeIfPresent(tab, forKey: .tab)
        case let .action(id, via, ms):
            try container.encode("action", forKey: .t)
            try container.encode(id, forKey: .id)
            try container.encode(via, forKey: .via)
            try container.encode(ms, forKey: .ms)
        case let .counts(counts):
            // The counts' fields sit beside `t` (serde's internal tag), not under a key.
            try container.encode("counts", forKey: .t)
            try counts.encode(to: encoder)
        }
    }
}
