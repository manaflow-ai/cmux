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
            "local_conversations": .bool(local.supports(caps.localConversations)),
        ])
        return .object(["available": .bool(home.isAvailable), "home_workspace": setup, "conversations": .array(conversations),
                        "page": page(services: services)])
    }
}
