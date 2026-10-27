import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextSettings

/// `debug.home`: the local conversation projection (plans/cmux-next/home.md) and whether Home is
/// classic (`classic`, the MessagesLab GUI checks need it), for automation on a never-key test window.
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
            // The running agent reply Home grows in its bubble (HomeStore.drafts).
            if let draft = home.homeStore.drafts[ConversationID(summary.id)] {
                row["draft"] = .object(["turn": .string(draft.turn.rawValue), "author": .string(draft.participant.rawValue),
                                        "text": .string(draft.text)])
            }
            // The Chief's running run (`chief-live-v1`, HomeStore.live): the reply so far and its activity line.
            if let live = home.homeStore.liveRun(in: ConversationID(summary.id)) {
                row["live"] = .object(["run": .string(live.run), "turn": .string(live.turn.rawValue),
                                       "author": .string(live.participant.rawValue), "text": .string(live.text),
                                       "activity": live.activity.map { .string($0.line) } ?? .null])
            }
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
        let workspace = home.homeWorkspace
        let tabs = workspace?.screens.flatMap(\.panes).flatMap(\.tabs) ?? []
        let setup: CmuxNextSettings.JSONValue = .object([
            "step": .string(home.homeWorkspaceStep),
            "workspace": workspace.map { .string($0.id) } ?? .null,
            "kind": workspace?.kind.map(CmuxNextSettings.JSONValue.string) ?? .null,
            "tab_kinds": .array(tabs.map { .string(String(describing: $0.kind)) }),
            "workspace_kind": .bool(local.supports(DaemonCapability.workspaceKind.rawValue)),
            "conversation_tabs": .bool(local.supports(DaemonCapability.conversationTabs.rawValue)),
            "local_conversations": .bool(home.chief.supports(DaemonCapability.localConversations.rawValue)),
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
                        "conversations": .array(conversations), "page": page(services: services), "classic": .bool(home.dock.isClassic),
                        "dock": dock(services: services), "hosted_chief": hosted(home),
                        "migration_notice": home.migrationNotice.map { .string($0) } ?? .null])
    }

    /// `hosted_chief`: the Hosted Chief proof's view (scripts/cmux-next/hosted-chief-proof.py).
    static func hosted(_ home: HomeService) -> CmuxNextSettings.JSONValue {
        .init(foundation: home.hostedChief.debugState(cloud: home.cloudChiefs, tab: home.tabChiefs, shown: home.cloudChief?.mainConversation)) ?? .null
    }
}
