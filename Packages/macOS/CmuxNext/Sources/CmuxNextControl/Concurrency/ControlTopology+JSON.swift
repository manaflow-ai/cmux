public import CmuxNextSettings

/// Wire form of the topology for `snapshot.get` (cmux-next native). Every
/// object prints its public id as `id` (`win_…`, `ws_…`, `screen_…`,
/// `pane_…`, `tab_…`, `term_…`) and a model key as `key` where the two
/// differ, so the CLI can pass `id` back as a target
/// (plans/cmux-next/state-ownership.md 4.3).
extension ControlTopology {
    public var json: JSONValue {
        let workspaceIDs = Dictionary(workspaces.map { ($0.id, $0.publicID) }, uniquingKeysWith: { first, _ in first })
        func workspace(_ key: String?) -> JSONValue { .optional(key.map { workspaceIDs[$0] ?? $0 }) }
        return [
            "loaded": .bool(isLoaded),
            "daemon_state": .string(daemonState),
            "daemon_failure": daemonFailure.map { .string($0) } ?? .null,
            "sequence": JSONValue.number(Double(daemonSequence)),
            "focus": [
                "window": .optional(focus.windowID.map(ControlWindowInfo.publicID(forKey:))), "workspace": workspace(focus.workspaceID),
                "pane": .optional(focus.paneID), "tab": .optional(focus.tabID),
            ],
            "windows": .array(windows.map { window in
                [
                    "id": .string(window.publicID), "key": .string(window.id), "workspace": workspace(window.workspaceID),
                    "workspaces": .array(window.workspaceIDs.map { .string(workspaceIDs[$0] ?? $0) }),
                    "key_window": .bool(window.isKey), "visible": .bool(window.isVisible), "focused_pane": .optional(window.focusedPaneID),
                ]
            }),
            "workspace_groups": .array(workspaceGroups.map(\.json)),
            "workspaces": .array(workspaces.map(\.json)),
            "sessions": .array(sessions.map(\.json)),
        ]
    }
}

extension ControlSessionInfo {
    public var json: JSONValue {
        ["id": .string(id), "qualifier": .string(qualifier), "machine": .string(machineID), "machine_name": .optional(machineName),
         "session_name": .optional(sessionName), "home": .bool(isHome), "state": .string(state), "transport": .string(transport)]
    }
}

extension ControlWorkspaceGroupInfo {
    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "color": .optional(color), "collapsed": .bool(isCollapsed)]
    }
}

extension ControlWorkspaceInfo {
    public var json: JSONValue {
        ["id": .string(publicID), "key": .string(id), "handle": .string(handle), "name": .string(name), "title": .optional(title),
         "color": .optional(color), "icon": .optional(icon), "group": .optional(groupID), "unread": JSONValue(unreadCount),
         "machine": .optional(machine), "screens": .array(screens.map(\.json)), "session": .optional(sessionID)]
    }
}

extension ControlScreenInfo {
    public var json: JSONValue {
        ["id": .string(id), "handle": .string(handle), "name": .optional(name), "zoomed_pane": .optional(zoomedPaneID),
         "panes": .array(panes.map(\.json))]
    }
}

extension ControlPaneInfo {
    public var json: JSONValue {
        ["id": .string(id), "handle": .string(handle), "name": .optional(name), "selected_tab": .optional(selectedTabID),
         "tabs": .array(tabs.map(\.json) + pageTabs.map(\.json)), "tab_groups": .array(tabGroups.map(\.json))]
    }
}

extension ControlPageTabInfo {
    public var json: JSONValue {
        ["id": .string(id), "kind": "page", "page": .string(page), "title": .string(title), "selected": .bool(isSelected)]
    }
}

extension ControlTabInfo {
    public var json: JSONValue {
        [
            "id": .string(id), "surface": .string(surface), "kind": .string(page == nil ? kind : "page"), "page": .optional(page),
            "title": .string(title), "name": .optional(name),
            "terminal": .optional(terminalResourceID ?? terminalID), "terminal_key": .optional(terminalID),
            "columns": columns.map { JSONValue($0) } ?? .null,
            "rows": rows.map { JSONValue($0) } ?? .null, "cwd": .optional(cwd), "url": .optional(url),
            "git_branch": .optional(gitBranch), "pinned": .bool(isPinned), "dead": .bool(isDead), "unread": .bool(hasUnread),
            "tab_group": .optional(tabGroupID), "agent_state": .optional(agentState),
            "agent_session": .optional(agentSessionID),
        ]
    }
}

extension ControlTabGroupInfo {
    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "color": .optional(color), "collapsed": .bool(isCollapsed),
         "members": .array(memberIDs.map(JSONValue.string))]
    }
}

extension JSONValue {
    static func optional(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
}
