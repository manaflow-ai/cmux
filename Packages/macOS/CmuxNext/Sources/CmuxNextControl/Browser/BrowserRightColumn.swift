import CmuxNextSettings
import Foundation

/// The column `browser.page.right` drives pages in. For a Chief turn (`caller.home_chat`) or a call with no
/// caller it is the column right of the Home chat, where every Chief shows and drives pages
/// (plans/cmux-next/chief-browser-use-DESIGN.md): the Home workspace (`kind == "home"`) holds the chat as a
/// page tab (`home-dock`) in a docked pane, and the first scrolling column right of that pane is the target.
/// For an agent in a workspace of its own (an agent chat outside Home, a terminal) it is that caller's own
/// place (``ControlCallerPlacement``): its helper column, never Home's.
struct BrowserRightColumn: Sendable, Equatable {
    var workspace: ControlWorkspaceInfo
    /// The chat's pane (the caller's own pane for a workspace agent).
    var dock: ControlPaneInfo
    /// The column right of the chat; nil when there is none (for a workspace agent: no helper column,
    /// so its tab opens in a new column right of it).
    var pane: ControlPaneInfo?
    /// The browser tabs of other workspaces the column mirrors (`browser.page.mirror`), in its order.
    var mirroredTabs: [ControlTabInfo] = []
    /// The workspace agent whose place this is; nil for the Home chat's column.
    var caller: ControlCallerPlacement?

    /// The column for `params`' caller. A Chief turn, a caller in the Home workspace, a terminal the topology
    /// does not show (another session's) or no caller: Home's (nil without a Home workspace). An agent chat
    /// outside Home or a terminal: its own place. An agent the topology does not show is refused.
    static func resolve(params: [String: JSONValue], in topology: ControlTopology) throws -> Self? {
        guard let caller = try ControlCaller(params) else { return resolve(in: topology) }
        guard let location = ControlCallerLocation.resolve(caller, in: topology) else {
            if caller.agentSession != nil, !caller.homeChat { throw BrowserCallerTarget.missingCaller(caller) }
            return resolve(in: topology)
        }
        guard location.workspace.kind != "home" else { return resolve(in: topology) }
        let placement = ControlCallerPlacement(location)
        let pane: ControlPaneInfo? = switch placement.kind {
        case .helperColumn: placement.pane(for: "browser")
        case .ownPane: location.pane
        case .newColumn: nil
        }
        return Self(workspace: location.workspace, dock: location.pane, pane: pane, caller: placement)
    }

    /// The browser tabs the agent's own tab is looked for among: the column's for Home; every one of its
    /// workspace for a workspace agent, whose tab the app may have placed in a pane the topology's columns
    /// do not name (a split beside it), so that the next verb finds the tab it opened.
    var ownedTabs: [ControlTabInfo] {
        guard caller != nil else { return browserTabs }
        return workspace.panes.flatMap(\.tabs).filter { $0.kind == "browser" && $0.page == nil }
    }

    /// The Home workspace's chat pane and its right column, nil without a Home workspace.
    static func resolve(in topology: ControlTopology) -> Self? {
        let homes = topology.workspaces.filter { $0.kind == "home" }
        let candidates = homes.isEmpty ? topology.workspaces : homes
        for workspace in candidates {
            for screen in workspace.screens {
                let chat: ControlPaneInfo? = screen.panes.first { pane in pane.tabs.contains { tab in tab.page == "home-dock" } }
                let docked: ControlPaneInfo? = workspace.kind == "home" ? screen.panes.first { pane in pane.dock != nil } : nil
                guard let dock = chat ?? docked else { continue }
                let pane = ControlCallerLocation.besidePane(of: dock, on: screen)
                let mirrored = pane?.mirroredTabIDs ?? []
                let tabs = mirrored.isEmpty ? [] : topology.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .filter { mirrored.contains($0.id) }
                return Self(workspace: workspace, dock: dock, pane: pane,
                            mirroredTabs: mirrored.compactMap { id in tabs.first { $0.id == id } })
            }
        }
        return nil
    }

    /// The app browser tabs of the right column, in strip order.
    var browserTabs: [ControlTabInfo] {
        guard let pane else { return [] }
        return pane.tabs.filter { (tab: ControlTabInfo) -> Bool in tab.kind == "browser" && tab.page == nil }
    }

    /// The browser tab the column shows (its own or a mirrored one), else its last browser tab.
    var shownBrowserTab: ControlTabInfo? {
        let tabs = browserTabs
        if let selected = pane?.selectedTabID,
           let shown = tabs.first(where: { $0.id == selected }) ?? mirroredTabs.first(where: { $0.id == selected }) { return shown }
        return tabs.last
    }
}
