import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHomeModel
import CmuxNextSettings

/// `debug.home` `page`: the Home page's conversation list as the active
/// window shows it (sections, rows, the shown conversation), the user's
/// Chiefs and team size, for preflights on a never-key test window.
extension DebugHome {
    /// Contacts the user has no direct conversation with.
    static func teammatesWithoutDM(rows: [InboxRow], contacts: [HomeContact]) -> Int {
        let peers = Set(rows.filter { $0.kind == .direct }.flatMap { $0.summary.participants.map(\.id) })
        return contacts.filter { !peers.contains($0.id) }.count
    }

    static func page(services: AppServices) -> CmuxNextSettings.JSONValue {
        let home = services.home
        let store = home.homeStore
        // The Messages page of the active window (classic Home's, else the docked one): its list draws these lines.
        let view = AppActions.listedPage(services)
        let listed = HomeArchivedChiefs(home.directory.archivedChiefs, me: store.me?.id).visible(store.rows)
        let lines: [CmuxNextSettings.JSONValue] = listed.homeLines.map { line in
            switch line {
            case .header(let kind): return .object(["header": .string(String(describing: kind))])
            case .row(let row):
                return .object([
                    "id": .string(row.id.rawValue), "title": .string(row.title), "kind": .string(String(describing: row.kind)),
                    "owner": .string(row.summary.owner.rawValue), "unread": .number(Double(row.unread)),
                    "mentions": .number(Double(row.mentions)), "pinned": .bool(row.isPinned),
                    // What the tile and row preview read: the inbox entry's newest message
                    // (its conversation and seq) and the summary's last_seq.
                    "preview": .string(row.preview), "last_seq": .number(Double(row.summary.lastSeq)),
                    "preview_source": row.summary.lastMessage.map { message in
                        .object(["message": .string(message.id.rawValue), "conversation": .string(message.conversation.rawValue),
                                 "seq": .number(Double(message.seq))])
                    } ?? .null,
                    "participants": .array(row.summary.participants.map { person in
                        .object(["id": .string(person.id.rawValue), "name": .string(person.displayName),
                                 "invited": .bool(person.membership == .invited), "chief": .bool(person.isChief)])
                    }),
                ])
            }
        }
        let fields: [String: JSONValue] = [
            "online": .bool(store.isOnline),
            "me": store.me.map { .string($0.id.rawValue) } ?? .null,
            "shown": view?.shown.map { .string($0.rawValue) } ?? .null,
            // The opened transcript as the store holds it, to compare with the row's preview_source.
            "shown_transcript": view?.shown.map { id -> JSONValue in
                let items = store.transcript(for: id)
                let lastSeq: JSONValue = items.compactMap(\.seq).max().map { .number(Double($0)) } ?? .null
                return .object(["conversation": .string(id.rawValue), "count": .number(Double(items.count)), "last_seq": lastSeq])
            } ?? .null,
            // Teammates with no DM yet (the search's Teammates section draws from these).
            "teammates_without_dm": .number(Double(Self.teammatesWithoutDM(rows: store.rows, contacts: home.contacts()))),
            "lines": .array(lines),
            // Every Home tab (`home.tab`): its key, window and shown conversation.
            "tabs": .array(((services.pages.provider(.homeTab) as? HomePageTab)?.tabs ?? []).map { tab -> JSONValue in
                .object([
                    "key": .string(tab.key),
                    "window": tab.view.window.flatMap { window in services.windows.controllers.first { $0.window === window }?.state.id }
                        .map { .string($0) } ?? .null,
                    "visible": .bool(tab.view.window != nil && !tab.view.isHiddenOrHasHiddenAncestor),
                    "shown": tab.view.shown.map { .string($0.rawValue) } ?? .null,
                ])
            }),
            "chiefs": .array(home.directory.chiefs.map { chief -> JSONValue in
                .object(["id": .string(chief.id), "name": .string(chief.name), "default": .bool(chief.isDefault),
                         "main_conversation": chief.mainConversation.map { .string($0) } ?? .null])
            }),
            "archived_chiefs": .array(home.directory.archivedChiefs.sorted().map { .string($0) }),
            "team_members": .number(Double(home.directory.teamMembers.count)),
        ]
        return .object(fields)
    }
}
