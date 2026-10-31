#if DEBUG || CMUX_BENCH_HOOKS
import CmuxHomeCore
import CmuxNextChiefPetWiring
import CmuxNextHome
import CmuxNextSettings
import Foundation

/// DEBUG ONLY. `debug.home.sidebar_fixture` {count (default 5, at most 12),
/// pinned (default 3)}: lists that many fixture conversations in the active
/// window's Home sidebar (the sidebar only, never the store or the owner),
/// the first `pinned` of them pinned, so a pin drag can be proven on a test
/// window that has only its Chief. `count: 0` removes them.
/// `chiefs` [{id, name, mascot?}] lists one Chief DM each after them, each Chief wearing the
/// character `mascot` picks for it (``ChiefMascotPicks``; none: its own or the default).
/// `team` (at most 12) lists that many fixture team members with no DM after the conversations
/// (`team: 0` removes them). `width`, `select`, `search`, `unread` set the list's look (`HomeSidebarView.debugLook`),
/// after the rows (no `count` keeps them); the answer carries the header's frames.
/// `messages` [{row, text}] answers the list's message search with those messages of the fixture
/// rows (a message containing every typed word matches); `messages: []` gives the search back to
/// the owner. `query` types into the search field, as a person does.
/// `new_message` (a team size) opens New Message and fills its list with fixture Chiefs and teammates;
/// `intro` ("welcome" | "askFocus") shows that intro on the shown Chief (neither touches other rows).
/// `hover_draft: true` moves the synthesized pointer (`DebugHover`) onto the New Message row, so
/// its x shows (captures of the row's hover).
@MainActor
enum DebugHomeSidebarFixture {
    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        // The docked Home's list (a Home tab), else classic Home's top page.
        guard let page = HomeDockTab.view(services)?.messages ?? services.windows.active?.topPages.views[.home] as? TopHomePageView else {
            return .object(["error": .string("no Home page in the active window")])
        }
        if let raw = params["intro"]?.stringValue, let kind = ChiefIntroKind(rawValue: raw) { page.host?.transcript.showFirstRunIntro(kind) }
        if let size = params["new_message"]?.intValue {
            if !page.isComposingNewMessage { page.presentNewMessage() }
            page.newMessage?.field.debugFillFixture(team: Array(HomeSidebarFixtureRows.names.prefix(max(0, size))))
            return .object(["rows": .number(Double(page.newMessage?.field.suggestions.rows.count ?? -1))])
        }
        if params["hover_draft"]?.boolValue == true, let window = page.window, let point = page.list.draftRowCenterInWindow {
            return .object(["owners": .number(Double(DebugHover.move(to: point, in: window)))])
        }
        if params["intro"] != nil { return .object(["intro": .bool(page.host != nil)]) }
        if let team = params["team"]?.intValue {
            page.sidebar.debugTeam = HomeSidebarFixtureRows.names.prefix(max(0, team)).reversed().enumerated().map { i, name in
                HomeContact(id: ParticipantID("user_fixture_team_\(i)"), name: name, source: .team)
            }
            page.list.update(page.sidebar.model())
        }
        if let messages = params["messages"]?.arrayValue { fixtureMessages(messages, page: page) }
        if params["count"] != nil || params["chiefs"] != nil
            || !["width", "select", "search", "unread", "team", "messages", "query"].contains(where: { params[$0] != nil }) {
            let count = min(HomeSidebarFixtureRows.names.count, max(0, params["count"]?.intValue ?? 5)), pinned = min(count, max(0, params["pinned"]?.intValue ?? 3))
            let me = services.home.homeStore.me ?? Participant(id: ParticipantID("user_debug_me"), kind: .human, displayName: "Me")
            let chiefs = (params["chiefs"]?.arrayValue ?? []).compactMap { entry -> (id: String, name: String)? in
                guard let id = entry["id"]?.stringValue, let name = entry["name"]?.stringValue else { return nil }
                if let mascot = entry["mascot"]?.stringValue { services.chiefMascotPicks.remember(mascot, for: id) }
                return (id, name)
            }
            services.home.debugChiefs = Set(chiefs.map(\.id))
            let fixture = HomeSidebarFixtureRows(me: me, now: Date())
            page.sidebar.debugRows = fixture.rows(count: count) + fixture.chiefRows(chiefs)
            for row in page.sidebar.debugRows.prefix(pinned) where !page.sidebar.pins.isPinned(row) { page.sidebar.setPinned(true, row.id) }
            page.list.update(page.sidebar.model())
        }
        guard let look = page.list.debugLook(width: params["width"]?.doubleValue, select: params["select"]?.intValue, unread: params["unread"]?.boolValue,
                                             search: params["search"]?.boolValue, query: params["query"]?.stringValue) else {
            return .object(["error": .string("no such row")])
        }
        return JSONValue(foundation: look.merging(["rows": page.sidebar.debugRows.map(\.id.rawValue)]) { a, _ in a }) ?? .null
    }

    /// The list's message search answers from `messages` ({row, text}: a message in the fixture row
    /// at `row`, an hour apart, newest first); none gives the search back to the owner.
    static func fixtureMessages(_ messages: [JSONValue], page: TopHomePageView) {
        guard !messages.isEmpty else { page.list.debugMessageHits = nil; return }
        let rows = page.sidebar.debugRows
        let now = Date()
        let hits = messages.enumerated().compactMap { i, entry -> HomeSearchHit? in
            guard let row = entry["row"]?.intValue, rows.indices.contains(row), let text = entry["text"]?.stringValue else { return nil }
            let conversation = rows[row].id // checked: indices.contains above
            let message = Message(id: MessageID("msg_fixture_\(i)"), conversation: conversation, seq: Seq(i + 1),
                                  clientMessageID: IdempotencyKey("msg_fixture_\(i)"), author: ParticipantID("user_fixture_\(row)"),
                                  parts: [.text(text)], createdAt: now.addingTimeInterval(Double(-(i + 1) * 3600)))
            return HomeSearchHit(conversation: conversation, message: message, highlights: [])
        }
        page.list.debugMessageHits = hits
    }
}
#endif
