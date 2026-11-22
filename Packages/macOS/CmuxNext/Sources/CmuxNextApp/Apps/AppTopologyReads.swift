import CmuxNextApps
import CmuxNextControl
import CmuxNextDaemon
import Foundation

/// App-facing shapes of the control snapshot (the mirror the control
/// socket answers reads from). Field names follow the cmux-tui resource
/// ops the samples were written against (`agent.list`, `terminal.get`).
nonisolated enum AppTopologyReads {
    static func workspaces(_ topology: ControlTopology) -> AppJSON {
        .array(topology.workspaces.map { ws in
            [
                "id": .string(ws.id), "name": .string(ws.name), "title": ws.title.map(AppJSON.string) ?? .null,
                "color": ws.color.map(AppJSON.string) ?? .null, "group": ws.groupID.map(AppJSON.string) ?? .null,
                "unread": .number(Double(ws.unreadCount)), "session": ws.sessionID.map(AppJSON.string) ?? .null,
                "tab_count": .number(Double(ws.panes.reduce(0) { $0 + $1.tabs.count })),
                "focused": .bool(topology.focus.workspaceID == ws.id),
            ]
        })
    }

    static func tabs(_ topology: ControlTopology, workspace: String?) -> AppJSON {
        var out: [AppJSON] = []
        for ws in topology.workspaces where workspace == nil || ws.id == workspace {
            for pane in ws.panes {
                for tab in pane.tabs { out.append(tabJSON(tab, pane: pane.id, workspace: ws.id)) }
            }
        }
        return .array(out)
    }

    static func agents(_ topology: ControlTopology) -> AppJSON {
        var out: [AppJSON] = []
        for ws in topology.workspaces {
            for pane in ws.panes {
                for tab in pane.tabs {
                    guard let state = tab.agentState, state != "unknown" else { continue }
                    out.append([
                        "id": .string(tab.id), "state": .string(state), "terminal_id": tab.terminalID.map(AppJSON.string) ?? .null,
                        "tab_id": .string(tab.id), "workspace_id": .string(ws.id), "source": "terminal",
                        "extra": ["name": .string(tab.name ?? tab.title), "cwd": tab.cwd.map(AppJSON.string) ?? .null],
                    ])
                }
            }
        }
        return .array(out)
    }

    static func terminal(_ topology: ControlTopology, id: String) -> AppJSON? {
        for ws in topology.workspaces {
            for pane in ws.panes {
                for tab in pane.tabs where tab.terminalID == id {
                    return [
                        "terminal_id": .string(id), "tab_id": .string(tab.id), "pane_id": .string(pane.id), "workspace_id": .string(ws.id),
                        "title": .string(tab.title), "cwd": tab.cwd.map(AppJSON.string) ?? .null, "dead": .bool(tab.isDead),
                    ]
                }
            }
        }
        return nil
    }

    static func notification(_ entry: ListNotificationsRequest.Entry) -> AppJSON {
        [
            "id": .string(entry.id), "title": .string(entry.title), "subtitle": entry.subtitle.map(AppJSON.string) ?? .null,
            "body": .string(entry.body), "level": .string(entry.level.rawValue), "acknowledged": .bool(entry.acknowledged),
            "created_at_ms": .number(Double(entry.createdAtMs)),
        ]
    }

    private static func tabJSON(_ tab: ControlTabInfo, pane: String, workspace: String) -> AppJSON {
        [
            "id": .string(tab.id), "kind": .string(tab.kind), "title": .string(tab.title), "name": tab.name.map(AppJSON.string) ?? .null,
            "terminal_id": tab.terminalID.map(AppJSON.string) ?? .null, "cwd": tab.cwd.map(AppJSON.string) ?? .null,
            "url": tab.url.map(AppJSON.string) ?? .null, "git_branch": tab.gitBranch.map(AppJSON.string) ?? .null,
            "pinned": .bool(tab.isPinned), "unread": .bool(tab.hasUnread), "agent_state": tab.agentState.map(AppJSON.string) ?? .null,
            "pane_id": .string(pane), "workspace_id": .string(workspace),
        ]
    }

    /// Change fingerprints per event stream (`<family>.changed`).
    static func fingerprints(_ topology: ControlTopology) -> [String: Int] {
        var workspaces = Hasher()
        var tabs = Hasher()
        var agents = Hasher()
        for ws in topology.workspaces {
            workspaces.combine(ws.id); workspaces.combine(ws.name); workspaces.combine(ws.unreadCount); workspaces.combine(ws.color)
            for pane in ws.panes {
                for tab in pane.tabs {
                    tabs.combine(tab)
                    if let state = tab.agentState { agents.combine(tab.id); agents.combine(state); agents.combine(tab.title) }
                }
            }
        }
        workspaces.combine(topology.focus.workspaceID)
        return ["workspace.changed": workspaces.finalize(), "tab.changed": tabs.finalize(), "agent.changed": agents.finalize()]
    }
}
