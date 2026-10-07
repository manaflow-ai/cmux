import AppKit
import CmuxHomeCore
import CmuxNextHome
import CmuxNextSettings

/// `debug.home` `page`: the Home page's conversation list as the active
/// window shows it (sections, rows, the shown conversation), the user's
/// Chiefs and team size, for preflights on a never-key test window.
extension DebugHome {
    static func frame(_ rect: NSRect) -> CmuxNextSettings.JSONValue {
        .object(["x": .number(Double(rect.minX)), "y": .number(Double(rect.minY)),
                 "width": .number(Double(rect.width)), "height": .number(Double(rect.height))])
    }

    /// Contacts the user has no direct conversation with.
    static func teammatesWithoutDM(rows: [InboxRow], contacts: [HomeContact]) -> Int {
        let peers = Set(rows.filter { $0.kind == .direct }.flatMap { $0.summary.participants.map(\.id) })
        return contacts.filter { !peers.contains($0.id) }.count
    }

    static func page(services: AppServices) -> CmuxNextSettings.JSONValue {
        let home = services.home
        let store = home.homeStore
        let view = services.windows.active?.topPages.views[.home] as? TopHomePageView
        let lines: [CmuxNextSettings.JSONValue] = (view?.lines ?? []).map { line in
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
        return .object([
            "online": .bool(store.isOnline),
            "me": store.me.map { .string($0.id.rawValue) } ?? .null,
            "shown": view?.shown.map { .string($0.rawValue) } ?? .null,
            // The opened transcript as the store holds it, to compare with the row's preview_source.
            "shown_transcript": view?.shown.map { id in
                let items = store.transcript(for: id)
                return .object(["conversation": .string(id.rawValue), "count": .number(Double(items.count)),
                                "last_seq": items.compactMap(\.seq).max().map { .number(Double($0)) } ?? .null])
            } ?? .null,
            // Teammates with no DM yet (the search's Teammates section draws from these).
            "teammates_without_dm": .number(Double(Self.teammatesWithoutDM(rows: store.rows, contacts: home.contacts()))),
            // The open sheet (New Message, Invite, New Chief): its window number for debug.window_snapshot.
            "sheet": view?.window?.attachedSheet.map { JSONValue($0.windowNumber) } ?? .null,
            "lines": .array(lines),
            // The Messages-style sidebar as drawn: pinned grid, rows, its width.
            "sidebar": view.map { page in
                .object([
                    "pinned": .array(page.list.model.pinned.map { .string($0.id.rawValue) }),
                    "rows": .array(page.list.model.rows.map { .string($0.id.rawValue) }),
                    "selected": page.list.selection.map { .string($0.rawValue) } ?? .null,
                    "width": .number(Double(page.split.sidebarWidth)),
                    "window": page.window.flatMap { window in services.windows.controllers.first { $0.window === window }?.state.id }
                        .map { .string($0) } ?? .null,
                    "divider": page.split.dividerFrameInWindow.map(Self.frame) ?? .null,
                ])
            } ?? .null,
            // Every window's Home sidebar: its width and divider (window points from the top-left).
            "sidebar_windows": .array(services.windows.controllers.compactMap { controller in
                guard let page = controller.topPages.views[.home] as? TopHomePageView else { return nil }
                return .object([
                    "window": .string(controller.state.id),
                    "width": .number(Double(page.split.sidebarWidth)),
                    "divider": page.split.dividerFrameInWindow.map(Self.frame) ?? .null,
                ])
            }),
            "chiefs": .array(home.directory.chiefs.map { chief in
                .object(["id": .string(chief.id), "name": .string(chief.name), "default": .bool(chief.isDefault),
                         "main_conversation": chief.mainConversation.map { .string($0) } ?? .null])
            }),
            "archived_chiefs": .array(home.directory.archivedChiefs.sorted().map { .string($0) }),
            "team_members": .number(Double(home.directory.teamMembers.count)),
        ])
    }
}
