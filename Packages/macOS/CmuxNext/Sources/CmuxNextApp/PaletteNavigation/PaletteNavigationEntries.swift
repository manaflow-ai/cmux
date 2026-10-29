import CmuxNextControl
import CmuxNextDesign
import CmuxNextPalette
import Foundation

/// A sidebar group as Go to Workspace lists it: the active window's sidebar
/// draws the groups, so it is the source, not the daemon tree.
nonisolated struct PaletteNavigationGroup: Hashable {
    var id: String
    var name: String
    var color: GroupColor?
    /// Member workspace ids, in sidebar order.
    var workspaceIDs: [String]
}

/// Go to Workspace's group, pane and tab entries (pure; the tests call it).
/// Panes are listed only in a workspace with more than one: a lone pane is
/// its workspace. Tabs closing now are left out, as in Search Tabs.
nonisolated enum PaletteNavigationEntries {
    static func entries(_ topology: ControlTopology, groups: [PaletteNavigationGroup], lastActive: [String: Date],
                        closing: Set<String> = []) -> [PaletteNavigationEntry] {
        var groupOfWorkspace: [String: String] = [:]
        var entries: [PaletteNavigationEntry] = groups.map { group in
            for workspace in group.workspaceIDs where groupOfWorkspace[workspace] == nil { groupOfWorkspace[workspace] = group.name }
            return PaletteNavigationEntry(id: group.id, kind: .group(workspaceCount: group.workspaceIDs.count), title: group.name,
                                          color: group.color)
        }
        let focus = topology.focus
        for workspace in topology.workspaces {
            let groupTitle = groupOfWorkspace[workspace.id]
            let panes = workspace.panes
            for pane in panes {
                let tabs = pane.tabs.filter { !closing.contains($0.id) }
                if panes.count > 1, workspace.kind != "home" {
                    let selected = tabs.first { $0.id == pane.selectedTabID } ?? tabs.first
                    entries.append(PaletteNavigationEntry(
                        id: pane.id, kind: .pane, title: pane.name ?? selected?.title ?? "", workspaceTitle: workspace.name,
                        groupTitle: groupTitle, cwd: selected?.cwd, keywords: tabs.map(\.title), isCurrent: pane.id == focus.paneID,
                        lastUsed: tabs.compactMap { lastActive[$0.id] }.max()))
                }
                for tab in tabs {
                    entries.append(PaletteNavigationEntry(
                        id: tab.id, kind: .tab(kind(of: tab)), title: tab.title, workspaceTitle: workspace.name, groupTitle: groupTitle,
                        cwd: tab.cwd, url: tab.url, agent: tab.agent, sessionID: sessionID(of: tab), isCurrent: tab.id == focus.tabID,
                        lastUsed: lastActive[tab.id]))
                }
            }
        }
        return entries
    }

    /// The record's title of a tab that names nothing a person reads (an agent chat, a Home
    /// conversation or a page carry `about:blank`; a new tab none), replaced by `title`, the name
    /// its tab shows (`TabTitleResolver`). Cmd-P listed agent chats as "about:blank" (msg 11943).
    static func titled(_ entries: [PaletteNavigationEntry], title: (PaletteNavigationEntry) -> String?) -> [PaletteNavigationEntry] {
        entries.map { entry in
            guard case .tab = entry.kind, entry.title.isEmpty || entry.title == blankTitle,
                  let shown = title(entry), !shown.isEmpty else { return entry }
            var titled = entry
            titled.title = shown
            return titled
        }
    }

    /// The address a page-backed tab's record is titled with.
    static let blankTitle = "about:blank"

    /// What Copy Session ID copies: an agent chat's acpmux handle
    /// (`acp:<session id>`, the address `cmux agent message` and acpmux take),
    /// else the Claude Code or Codex session id of the tab's terminal.
    static func sessionID(of tab: ControlTabInfo) -> String? {
        if let session = tab.agentSessionID, !session.isEmpty { return PaletteNavigationEntry.acpPrefix + session }
        return tab.agentHarnessSessionID
    }

    static func kind(of tab: ControlTabInfo) -> PaletteNavigationEntry.TabKind {
        if tab.agentSessionID != nil { return .agentChat }
        switch tab.page {
        case "markdown": return .markdown
        case "editor": return .file
        case .some: return .page
        case nil: break
        }
        switch tab.kind {
        case "terminal": return .terminal
        case "browser": return .browser
        case "remote-terminal": return .remoteTerminal
        default: return .other
        }
    }
}
