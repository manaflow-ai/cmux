import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextSettings

/// `debug.home`: the local conversation projection
/// (plans/cmux-next/home.md), for automation on a never-key test window.
@MainActor
enum DebugHome {
    static func report(services: AppServices) -> CmuxNextSettings.JSONValue {
        let home = services.home
        let conversations: [CmuxNextSettings.JSONValue] = home.conversations.map { summary in
            var row: [String: CmuxNextSettings.JSONValue] = [
                "id": .string(summary.id), "title": .string(summary.title), "last_seq": .number(Double(summary.lastSeq)),
                "rev": .number(Double(summary.rev)),
                "participants": .array(summary.participants.map { .string($0.id) }),
            ]
            // What the Home view shows (HomeStore: owner mirror + cache + intent log).
            let shown = home.homeStore.transcript(for: ConversationID(summary.id))
            row["shown_count"] = .number(Double(shown.count))
            row["shown_tail"] = .array(shown.suffix(20).map { item in
                .object(["seq": item.seq.map { .number(Double($0)) } ?? .null, "author": .string(item.author.rawValue),
                         "text": .string(item.plainText), "delivery": .string(String(describing: item.delivery))])
            })
            if let session = home.sessions[summary.id] {
                row["mirror_rev"] = session.mirror.map { .number(Double($0.rev)) } ?? .null
                row["pending"] = .array(session.log.entries.map { entry in
                    .object(["client_msg_id": .string(entry.clientMsgID), "state": .string(String(describing: entry.state))])
                })
                row["typing"] = .array(session.typing.sorted().map(CmuxNextSettings.JSONValue.string))
                row["tail"] = .array((session.mirror?.tail.suffix(10) ?? []).map { message in
                    .object(["seq": .number(Double(message.seq)), "author": .string(message.author),
                             "text": .string(message.parts.map(\.plainText).joined(separator: "\n"))])
                })
            }
            return .object(row)
        }
        let local = services.machines.local
        let caps = DaemonCapabilities.shared
        let workspace = home.homeWorkspace
        let tabs = workspace?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []
        let setup: CmuxNextSettings.JSONValue = .object([
            "step": .string(home.homeWorkspaceStep),
            "workspace": workspace.map { .string($0.id) } ?? .null,
            "kind": workspace?.kind.map(CmuxNextSettings.JSONValue.string) ?? .null,
            "tab_kinds": .array(tabs.map { .string(String(describing: $0.kind)) }),
            "workspace_kind": .bool(local.supports(caps.workspaceKind)),
            "conversation_tabs": .bool(local.supports(caps.conversationTabs)),
            "local_conversations": .bool(home.chief.supports(caps.localConversations)),
        ])
        let chief = home.chief
        let owner: CmuxNextSettings.JSONValue = .object([
            "home": .string(chief.home.root.path),
            "isolated": .bool(chief.home.isolated),
            "session": .string(chief.home.session),
            "connected": .bool(chief.connection != nil),
            "daemon_pid": chief.identity.map { .number(Double($0.pid)) } ?? .null,
            "error": chief.lastError.map(CmuxNextSettings.JSONValue.string) ?? .null,
            "store_online": .bool(home.homeStore.isOnline),
            "cache": home.homeStore.cache.map { .string($0.url.path) } ?? .null,
        ])
        return .object(["available": .bool(home.isAvailable), "chief_owner": owner, "home_workspace": setup,
                        "conversations": .array(conversations), "page": page(services: services)])
    }
}
