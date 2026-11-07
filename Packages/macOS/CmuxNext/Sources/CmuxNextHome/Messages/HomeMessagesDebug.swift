#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings

/// DEBUG ONLY. The app's DEBUG socket verbs on a Home that is the Messages page: the page draws the
/// list and the transcript, so it answers what the native Home's views did (DebugHomeSidebarFixture,
/// the dock list's `driveDockList`, the native transcript's `debug.home.drive`), through the one
/// page op `home.messages.debug` (webviews/src/pages/home-messages/debugCommands.ts).
///
/// - `debug.home.sidebar_fixture` (``sidebarFixture(_:)``): the page's `fixture` action (its rows,
///   look, New Message's people, an intro); `hover_draft` moves the pointer onto the New Message row.
/// - `debug.home.drive` (``drive(_:)``): `list` ops go to the page's `list` action, every other
///   action to its `drive` action.
/// - `debug.home` (``snapshot()``, ``merging(report:dock:tabs:)``): the list as drawn and the shown
///   transcript's tail, under the keys the native views filled (`dock.messages_list`, `messages_note`,
///   `messages_cloud`, `open_thread`, `transcript_tail`; `page.tabs[].transcript_tail`).
@MainActor
public struct HomeMessagesDebug {
    /// Calls a page op and waits up to the deadline for its answer; nil when none came.
    public typealias Ask = @MainActor (_ op: String, _ params: [String: JSONValue], _ within: Duration) async -> JSONValue?
    /// Moves the pointer onto the first element the CSS selector matches (`PageWebView.debugHover`).
    public typealias Hover = @MainActor (_ selector: String) async -> JSONValue

    /// The page op every action goes through.
    public static let op = "home.messages.debug"
    /// The New Message draft's row in the page's list (ConversationList's `DRAFT_ROW`).
    public static let draftRowSelector = "[data-list-row=\"home.newMessage\"]"
    /// How long a call that changes the page waits for it (a page still loading answers within it).
    public static let actionDeadline: Duration = .seconds(5)
    /// How long `debug.home` waits for each page's read: a poll must not stall on a page that is not up.
    public static let snapshotDeadline: Duration = .milliseconds(400)

    private let ask: Ask
    private let hover: Hover

    public init(ask: @escaping Ask, hover: @escaping Hover) {
        self.ask = ask
        self.hover = hover
    }

    private static func failure(_ why: String) -> JSONValue { .object(["error": .string(why)]) }

    private func call(_ action: String, _ params: [String: JSONValue], within: Duration = Self.actionDeadline) async -> JSONValue? {
        await ask(Self.op, params.merging(["action": .string(action)]) { _, new in new }, within)
    }

    /// `debug.home.sidebar_fixture` {count, pinned, chiefs, channels, team, width, select, search,
    /// unread, new_message, intro, hover_draft} on the page.
    public func sidebarFixture(_ params: [String: JSONValue]) async -> JSONValue {
        if params["hover_draft"]?.boolValue == true { return await hover(Self.draftRowSelector) }
        return await call("fixture", params) ?? Self.failure("the Home Messages page did not answer")
    }

    /// `debug.home.drive` {action, …} on the page: `list` {op, conversation, item?}, else the page's
    /// transcript and composer (focus, type, send, texts, typing, thread, thread_state, escape, reply).
    public func drive(_ params: [String: JSONValue]) async -> JSONValue {
        let action = params["action"]?.stringValue ?? ""
        var forwarded = params
        forwarded["tab"] = nil
        forwarded["window"] = nil
        if action == "list" { return await call("list", forwarded) ?? Self.failure("the Home Messages page did not answer") }
        forwarded["drive"] = .string(action)
        return await call("drive", forwarded) ?? Self.failure("no Home conversation is shown")
    }

    /// The page's list and shown transcript (`snapshot`), nil when the page does not answer in time.
    public func snapshot() async -> [String: JSONValue]? {
        await call("snapshot", [:], within: Self.snapshotDeadline)?.objectValue
    }

    /// `report` (the `debug.home` answer) with the pages' reads under the native views' keys: the
    /// docked page's into `dock`, each Home tab's (by key) into its `page.tabs` entry.
    public static func merging(report: JSONValue, dock: [String: JSONValue]?, tabs: [String: [String: JSONValue]]) -> JSONValue {
        guard case .object(var fields) = report else { return report }
        if case .object(var docked)? = fields["dock"] {
            let read = dock ?? [:]
            docked["messages_list"] = read["list"] ?? .array([])
            docked["messages_note"] = read["note"] ?? .null
            docked["messages_cloud"] = read["cloud"] ?? .null
            docked["open_thread"] = read["open_thread"] ?? .null
            docked["transcript_tail"] = read["transcript_tail"] ?? .array([])
            fields["dock"] = .object(docked)
        }
        if case .object(var page)? = fields["page"], case .array(let entries)? = page["tabs"] {
            page["tabs"] = .array(entries.map { entry in
                guard case .object(var tab) = entry else { return entry }
                tab["transcript_tail"] = tab["key"]?.stringValue.flatMap { tabs[$0]?["transcript_tail"] } ?? .array([])
                return .object(tab)
            })
            fields["page"] = .object(page)
        }
        return .object(fields)
    }
}
#endif
