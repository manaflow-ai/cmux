#if DEBUG
import CmuxHomeCore
import CmuxNextHome
import AppKit
import CmuxNextSettings
import Foundation

/// DEBUG ONLY. `debug.home.sidebar_fixture` {count (default 5, at most 12),
/// pinned (default 3)}: lists that many fixture conversations in the active
/// window's Home sidebar (the sidebar only, never the store or the owner),
/// the first `pinned` of them pinned, so a pin drag can be proven on a test
/// window that has only its Chief. `count: 0` removes them.
///
/// The list's look for screenshots, each optional and applied after the rows (no `count` keeps
/// the rows as they are): `width` (the list's width, clamped as a divider drag is), `select`
/// (the n-th row, 0 first, below the pinned tiles), `search` (true: the field takes the
/// keyboard; false: the search ends and the field lets go), `unread` (the Unread toggle).
/// The answer carries the header's frames (`header`).
@MainActor
enum DebugHomeSidebarFixture {
    static let names = ["Austin", "Lucas Wang", "Aziz Ali", "Mia Chen", "Noah Park", "Iris Lee",
                        "Omar Diaz", "Zoe Kim", "Sam Fox", "Ana Ruiz", "Leo Moss", "Ivy Hart"]

    static func handle(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let page = services.windows.active?.topPages.views[.home] as? TopHomePageView else {
            return .object(["error": .string("no Home page in the active window")])
        }
        let looks = ["width", "select", "search", "unread"].contains { params[$0] != nil }
        if params["count"] != nil || !looks {
            let count = min(names.count, max(0, params["count"]?.intValue ?? 5))
            let pinned = min(count, max(0, params["pinned"]?.intValue ?? 3))
            let me = services.home.homeStore.me ?? Participant(id: ParticipantID("user_debug_me"), kind: .human, displayName: "Me")
            page.sidebar.debugRows = rows(count: count, me: me, now: Date())
            for row in page.sidebar.debugRows.prefix(pinned) where !page.sidebar.pins.isPinned(row) {
                page.sidebar.setPinned(true, row.id)
            }
            page.list.update(page.sidebar.model())
        }
        if let width = params["width"]?.doubleValue { page.split.setWidth(CGFloat(width)) }
        if let index = params["select"]?.intValue {
            let rows = page.list.model.rows
            guard rows.indices.contains(index) else { return .object(["error": .string("no row \(index)")]) }
            page.list.onSelect(rows[index].id)
            page.list.select(rows[index].id)
        }
        if let unread = params["unread"]?.boolValue { page.list.unreadOnly = unread }
        if let search = params["search"]?.boolValue { page.list.debugSearch(search) }
        page.layoutSubtreeIfNeeded()
        let h = page.list.header
        func frame(_ r: CGRect?) -> JSONValue {
            guard let r else { return .null }
            return .array([r.minX, r.minY, r.width, r.height].map { JSONValue.number(Double($0)) })
        }
        return .object([
            "rows": .array(page.sidebar.debugRows.map { .string($0.id.rawValue) }),
            "width": .number(Double(page.split.sidebarWidth)),
            "header": .object(["search": frame(h.search), "searchButton": frame(h.searchButton), "filter": frame(h.filter),
                               "compose": frame(h.compose), "buttonsCovered": .bool(h.buttonsCovered)]),
        ])
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
