import Foundation

/// The column right of the Home chat: where every Chief shows and drives
/// pages (plans/cmux-next/chief-browser-use-DESIGN.md). The Home workspace
/// (`kind == "home"`) holds the chat as a page tab (`home-dock`) in a docked
/// pane; the first scrolling column right of that pane is the target, the
/// same rule `beside_caller` uses for an agent's chat (ControlCaller).
struct BrowserRightColumn: Sendable, Equatable {
    var workspace: ControlWorkspaceInfo
    /// The chat's pane, never a target.
    var dock: ControlPaneInfo
    /// The column right of the chat; nil when the user has none open.
    var pane: ControlPaneInfo?
    /// The browser tabs of other workspaces the column mirrors (`browser.page.mirror`), in its order.
    var mirroredTabs: [ControlTabInfo] = []

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
