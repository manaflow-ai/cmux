public import CmuxNextSettings

/// Wire form of the topology for `snapshot.get` (cmux-next native). Compat
/// methods build the old app's shapes from the typed values instead.
extension ControlTopology {
    public var json: JSONValue {
        [
            "loaded": .bool(isLoaded),
            "daemon_state": .string(daemonState),
            "focus": focus.json,
            "windows": .array(windows.map(\.json)),
            "workspace_groups": .array(workspaceGroups.map(\.json)),
            "workspaces": .array(workspaces.map(\.json)),
        ]
    }
}

extension ControlFocus {
    public var json: JSONValue {
        ["window": .optional(windowID), "workspace": .optional(workspaceID), "pane": .optional(paneID), "tab": .optional(tabID)]
    }
}

extension ControlWindowInfo {
    public var json: JSONValue {
        ["id": .string(id), "workspace": .optional(workspaceID), "key": .bool(isKey), "visible": .bool(isVisible),
         "focused_pane": .optional(focusedPaneID)]
    }
}

extension ControlWorkspaceGroupInfo {
    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "color": .optional(color), "collapsed": .bool(isCollapsed)]
    }
}

extension ControlWorkspaceInfo {
    public var json: JSONValue {
        ["id": .string(id), "handle": .string(handle), "name": .string(name), "title": .optional(title), "color": .optional(color),
         "icon": .optional(icon), "group": .optional(groupID), "unread": JSONValue(unreadCount), "screens": .array(screens.map(\.json))]
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
         "tabs": .array(tabs.map(\.json)), "tab_groups": .array(tabGroups.map(\.json))]
    }
}

extension ControlTabInfo {
    public var json: JSONValue {
        [
            "id": .string(id), "surface": .string(surface), "kind": .string(kind), "title": .string(title), "name": .optional(name),
            "terminal": .optional(terminalID), "columns": columns.map { JSONValue($0) } ?? .null,
            "rows": rows.map { JSONValue($0) } ?? .null, "cwd": .optional(cwd), "url": .optional(url),
            "git_branch": .optional(gitBranch), "pinned": .bool(isPinned), "dead": .bool(isDead), "unread": .bool(hasUnread),
            "tab_group": .optional(tabGroupID), "agent_state": .optional(agentState),
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
