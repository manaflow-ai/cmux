import CmuxNextDaemon
import Foundation

/// Builds the shipped-iOS `mobile.workspace.list` result from the daemon
/// tree. Required row fields (decoder: `MobileSyncWorkspaceListResponse`)
/// are always present; optional ones only when the daemon knows them.
enum MobileWorkspaceRows {
    /// One located PTY: where the phone's surface id points in the tree.
    struct TerminalLocation: Sendable {
        var workspace: WorkspaceKey
        var tab: TabSnapshot
    }

    static func result(for tree: DaemonTree, selected: WorkspaceKey?,
                       createdWorkspace: WorkspaceKey? = nil, createdTerminal: TerminalID? = nil) -> JSONValue {
        var result: [String: JSONValue] = [
            "workspaces": .array(tree.workspaces.compactMap { row(for: $0, selected: selected) }),
            "groups": .array(tree.groups.sorted { $0.index < $1.index }.map(groupRow)),
        ]
        if let createdWorkspace { result["created_workspace_id"] = .string(MobileCompatIDs.workspaceID(createdWorkspace)) }
        if let createdTerminal, let id = MobileCompatIDs.surfaceID(createdTerminal) {
            result["created_terminal_id"] = .string(id)
        }
        return .object(result)
    }

    /// Every PTY tab of `workspace`, in screen/pane/tab order.
    static func terminals(of workspace: WorkspaceSnapshot) -> [(tab: TabSnapshot, focused: Bool)] {
        var found: [(TabSnapshot, Bool)] = []
        for screen in workspace.screens {
            for pane in screen.panes {
                for (index, tab) in pane.tabs.enumerated() where tab.kind == .pty && tab.terminalID != nil {
                    let focused = screen.active && screen.activePane == pane.id && pane.activeTab == index
                    found.append((tab, focused))
                }
            }
        }
        return found
    }

    /// The tab whose terminal maps to the phone's `surface_id`.
    static func locate(surfaceID: String, in tree: DaemonTree) -> TerminalLocation? {
        for workspace in tree.workspaces {
            guard let key = workspace.key else { continue }
            for (tab, _) in terminals(of: workspace) {
                if let terminal = tab.terminalID,
                   MobileCompatIDs.surfaceID(terminal)?.caseInsensitiveCompare(surfaceID) == .orderedSame {
                    return TerminalLocation(workspace: key, tab: tab)
                }
            }
        }
        return nil
    }

    private static func row(for workspace: WorkspaceSnapshot, selected: WorkspaceKey?) -> JSONValue? {
        guard let key = workspace.key else { return nil }
        let terminals = terminals(of: workspace)
        var row: [String: JSONValue] = [
            "id": .string(MobileCompatIDs.workspaceID(key)),
            "title": .string(workspace.displayName),
            "is_selected": .bool(selected.map { $0 == key } ?? workspace.active),
            "terminals": .array(terminals.compactMap { terminalRow($0.tab, focused: $0.focused) }),
        ]
        if let focused = terminals.first(where: \.focused)?.tab.cwd ?? terminals.first?.tab.cwd {
            row["current_directory"] = .string(focused)
        }
        if let group = workspace.group { row["group_id"] = .string(MobileCompatIDs.groupID(group)) }
        if let color = workspace.color, color.hasPrefix("#") { row["custom_color"] = .string(color) }
        if let unread = workspace.unreadCount {
            row["unread_count"] = .int(unread)
            row["has_unread"] = .bool(unread > 0)
        }
        return .object(row)
    }

    private static func terminalRow(_ tab: TabSnapshot, focused: Bool) -> JSONValue? {
        guard let terminal = tab.terminalID, let id = MobileCompatIDs.surfaceID(terminal) else { return nil }
        var row: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(tab.name.flatMap { $0.isEmpty ? nil : $0 } ?? tab.title),
            "is_focused": .bool(focused),
            "is_ready": .bool(!tab.dead),
        ]
        if let cwd = tab.cwd { row["current_directory"] = .string(cwd) }
        return .object(row)
    }

    private static func groupRow(_ group: WorkspaceGroupSnapshot) -> JSONValue {
        .object([
            "id": .string(MobileCompatIDs.groupID(group.id)),
            "name": .string(group.name),
            "is_collapsed": .bool(group.collapsed),
            "is_pinned": .bool(false),
        ])
    }
}
