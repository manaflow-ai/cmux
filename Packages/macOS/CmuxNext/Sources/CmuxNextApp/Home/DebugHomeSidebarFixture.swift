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
/// `new_message` (a team size) opens New Message and fills its list with fixture Chiefs and teammates;
/// `intro` ("welcome" | "askFocus") shows that intro on the shown Chief (neither touches other rows).
@MainActor
enum DebugHomeSidebarFixture {
    static let names = ["Austin", "Lucas Wang", "Aziz Ali", "Mia Chen", "Noah Park", "Iris Lee",
                        "Omar Diaz", "Zoe Kim", "Sam Fox", "Ana Ruiz", "Leo Moss", "Ivy Hart"]

    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        // The docked Home's list (a Home tab), else classic Home's top page.
        guard let page = HomeDockTab.view(services)?.messages ?? services.windows.active?.topPages.views[.home] as? TopHomePageView else {
            return .object(["error": .string("no Home page in the active window")])
        }
        if let raw = params["intro"]?.stringValue, let kind = ChiefIntroKind(rawValue: raw) { page.host?.transcript.showFirstRunIntro(kind) }
        if let size = params["new_message"]?.intValue {
            if !page.isComposingNewMessage { page.presentNewMessage() }
            page.newMessage?.field.debugFillFixture(team: Array(names.prefix(min(names.count, max(0, size)))))
            return .object(["rows": .number(Double(page.newMessage?.field.suggestions.rows.count ?? -1))])
        }
        if params["intro"] != nil { return .object(["intro": .bool(page.host != nil)]) }
        if let team = params["team"]?.intValue {
            page.sidebar.debugTeam = names.prefix(min(names.count, max(0, team))).reversed().enumerated().map { i, name in
                HomeContact(id: ParticipantID("user_fixture_team_\(i)"), name: name, source: .team)
            }
            page.list.update(page.sidebar.model())
        }
        if params["count"] != nil || params["chiefs"] != nil || !["width", "select", "search", "unread", "team"].contains(where: { params[$0] != nil }) {
            let count = min(names.count, max(0, params["count"]?.intValue ?? 5)), pinned = min(count, max(0, params["pinned"]?.intValue ?? 3))
            let me = services.home.homeStore.me ?? Participant(id: ParticipantID("user_debug_me"), kind: .human, displayName: "Me")
            let chiefs = (params["chiefs"]?.arrayValue ?? []).compactMap { entry -> (id: String, name: String)? in
                guard let id = entry["id"]?.stringValue, let name = entry["name"]?.stringValue else { return nil }
                if let mascot = entry["mascot"]?.stringValue { services.chiefMascotPicks.remember(mascot, for: id) }
                return (id, name)
            }
            services.home.debugChiefs = Set(chiefs.map(\.id))
            page.sidebar.debugRows = rows(count: count, me: me, now: Date()) + chiefRows(chiefs, me: me, now: Date())
            for row in page.sidebar.debugRows.prefix(pinned) where !page.sidebar.pins.isPinned(row) { page.sidebar.setPinned(true, row.id) }
            page.list.update(page.sidebar.model())
        }
        guard let look = page.list.debugLook(width: params["width"]?.doubleValue, select: params["select"]?.intValue, unread: params["unread"]?.boolValue, search: params["search"]?.boolValue) else { return .object(["error": .string("no such row")]) }
        return JSONValue(foundation: look.merging(["rows": page.sidebar.debugRows.map(\.id.rawValue)]) { a, _ in a }) ?? .null
    }

    /// One DM with each Chief, a minute apart, through the same mirror path real inbox rows take.
    static func chiefRows(_ chiefs: [(id: String, name: String)], me: Participant, now: Date) -> [InboxRow] {
        let summaries = chiefs.enumerated().map { i, chief in
            let at = now.addingTimeInterval(Double(-(i + 1) * 60))
            let other = Participant(id: ParticipantID(chief.id), kind: .agent, displayName: chief.name, agentClass: .chief)
            return ConversationSummary(id: ConversationID("conv_fixture_chief_\(i)"), title: chief.name, participants: [me, other],
                                       createdAt: at, updatedAt: at)
        }
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: me, conversations: summaries, rev: 1))
        return mirror.inboxRows(log: IntentLog())
    }

    /// One DM per name, an hour apart, through the same mirror path real inbox rows take.
    static func rows(count: Int, me: Participant, now: Date) -> [InboxRow] {
        let summaries = names.prefix(count).enumerated().map { i, name in
            let at = now.addingTimeInterval(Double(-(i + 1) * 3600))
            let other = Participant(id: ParticipantID("user_fixture_\(i)"), kind: .human, displayName: name)
            return ConversationSummary(id: ConversationID("conv_fixture_\(i)"), participants: [me, other], createdAt: at, updatedAt: at)
        }
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: me, conversations: summaries, rev: 1))
        return mirror.inboxRows(log: IntentLog())
    }
}
#endif
