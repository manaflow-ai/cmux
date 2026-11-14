import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// Keeps every open New Tab page's open tabs and workspaces current (Leo 2026-10-11: after rapid
/// creates the bar kept "about:blank workspace-7/8" rows for workspaces gone since). A page's
/// places were read once, when it opened or a spare was adopted; now a tab or workspace that
/// comes, goes or is renamed reaches each page still showing as a New Tab page
/// (``AgentPaneView/refreshNewTabPlaces(tabs:workspaces:)``), as seen from its own window. A
/// refresh lists every place, the tab the page was opened beside included.
///
/// Cheap while idle: with no New Tab page open it observes only the pages' ids. With one open, each
/// workspace's plain key (ids, titles, addresses, folders) is its own item (``ObservedItemsFeed``), and the rows,
/// favicons included, are built only when a key changed.
@MainActor
enum NewTabPlacesFeed {
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        ObservedItemsFeed<WorkspaceModel, [String]>(
            list: { [weak tabs, weak services] in
                guard let tabs, let services, !tabs.pageTabs.ids.isEmpty else { return nil }
                return services.machines.allWorkspaces.map(\.0)
            },
            // By object: two machines' workspaces may share an id (`handle:<n>` without the registry).
            id: { "\(ObjectIdentifier($0))" }, item: { workspace in key(workspace) },
            changed: { [weak tabs, weak services] in
                if let tabs, let services { push(tabs, services: services) }
            }).start()
    }

    /// Everything one workspace's bar rows are made of, as plain text: a change here is a change of rows.
    private static func key(_ workspace: WorkspaceModel) -> [String] {
        ["\(workspace.id)\t\(workspace.displayName)"] + workspace.screens.flatMap(\.panes).flatMap(\.tabs).map { tab in
            [tab.id, "\(tab.kind)", tab.displayTitle, tab.url ?? "", tab.cwd ?? "", tab.agentSession?.session ?? ""]
                .joined(separator: "\t")
        }
    }

    private static func push(_ tabs: AgentTabStore, services: AppServices) {
        for entry in tabs.newTabPages.entries {
            guard let view = tabs.views[entry.key] else { continue }
            let window = view.window.flatMap { services.windows.owner(of: $0) } ?? services.windows.active
            let places = NewTabPage.places(services, excluding: entry.key.key, current: window?.state.workspaceID)
            view.refreshNewTabPlaces(tabs: places.tabs, workspaces: places.workspaces)
        }
    }
}
