import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Keeps every open New Tab page's open tabs and workspaces current (Leo 2026-10-11: after rapid
/// creates the bar kept "about:blank workspace-7/8" rows for workspaces gone since). A page's
/// places were read once, when it opened or a spare was adopted; now a tab or workspace that
/// comes, goes or is renamed reaches each page still showing as a New Tab page
/// (``AgentPaneView/refreshNewTabPlaces(tabs:workspaces:)``), as seen from its own window. A
/// refresh lists every place, the tab the page was opened beside included.
///
/// Decision of 2026-11-16: the rows of each workspace are kept for the app's life (``NewTabPlacesKept``), so a change
/// maps the workspace that changed and no other, and a page's open and its refresh map none.
@MainActor
enum NewTabPlacesFeed {
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        services.newTabPlaces.follow(
            list: { [weak services] in services?.machines.allWorkspaces.map(\.0) },
            rows: { [weak services] workspace in services.map { NewTabPage.rows($0, workspace) } },
            changed: { [weak tabs, weak services] in
                if let tabs, let services { push(tabs, services: services) }
            })
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
