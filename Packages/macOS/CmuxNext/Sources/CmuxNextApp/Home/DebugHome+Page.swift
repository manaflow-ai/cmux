import CmuxHomeCore
import CmuxNextHome
import CmuxNextSettings

/// `debug.home` `page`: the Home page's conversation list as the active
/// window shows it (sections, rows, the shown conversation), the user's
/// Chiefs and team size, for preflights on a never-key test window.
extension DebugHome {
    static func page(services: AppServices) -> CmuxNextSettings.JSONValue {
        let home = services.home
        let store = home.homeStore
        let view = services.windows.active?.topPages.views[.home] as? TopHomePageView
        let lines: [CmuxNextSettings.JSONValue] = (view?.list.lines ?? []).map { line in
            switch line {
            case .header(let kind): return .object(["header": .string(String(describing: kind))])
            case .row(let row):
                return .object([
                    "id": .string(row.id.rawValue), "title": .string(row.title), "kind": .string(String(describing: row.kind)),
                    "owner": .string(row.summary.owner.rawValue), "unread": .number(Double(row.unread)),
                    "mentions": .number(Double(row.mentions)), "pinned": .bool(row.isPinned),
                    "participants": .array(row.summary.participants.map { person in
                        .object(["id": .string(person.id.rawValue), "name": .string(person.displayName),
                                 "invited": .bool(person.membership == .invited), "chief": .bool(person.isChief)])
                    }),
                ])
            }
        }
        return .object([
            "online": .bool(store.isOnline),
            "me": store.me.map { .string($0.id.rawValue) } ?? .null,
            "shown": view?.shown.map { .string($0.rawValue) } ?? .null,
            "lines": .array(lines),
            "chiefs": .array(home.directory.chiefs.map { chief in
                .object(["id": .string(chief.id), "name": .string(chief.name), "default": .bool(chief.isDefault),
                         "main_conversation": chief.mainConversation.map { .string($0) } ?? .null])
            }),
            "archived_chiefs": .array(home.directory.archivedChiefs.sorted().map { .string($0) }),
            "team_members": .number(Double(home.directory.teamMembers.count)),
        ])
    }
}
